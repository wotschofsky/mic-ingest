import SwiftUI

/// The hero screen: sessions on the recorder (one tab per microphone), the library they go to, one Import button.
struct ImportView: View {
    let openSession: (String) -> Void
    @Environment(SourceModel.self) private var source
    @Environment(ImportCoordinator.self) private var imports
    @Environment(LibraryModel.self) private var library
    @AppStorage("showFragments") private var showFragments = false
    @State private var preview = SessionPreview()

    var body: some View {
        Group {
            if source.hasSource {
                sessionList
            } else {
                ContentUnavailableView {
                    Label("Connect the DJI Mic", systemImage: "mic")
                } description: {
                    Text("Recordings appear here when the recorder is connected. You can also choose the folder that contains them.")
                } actions: {
                    Button("Choose Source Folder…") { source.chooseFolder() }
                }
            }
        }
        .navigationTitle("DJI Mic")
        .navigationSubtitle(source.sourceDescription)
        .toolbar {
            if source.transmitters.count > 1 {
                ToolbarItem(placement: .principal) {
                    Picker("Microphone", selection: Binding(get: { source.visibleTransmitter ?? "" }, set: { source.transmitterTab = $0 })) {
                        ForEach(source.transmitters, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("Each microphone has its own list")
                    .accessibilityIdentifier("microphone-tabs")
                }
            }
            ToolbarItemGroup {
                if source.hasSource {
                    Button("Rescan", systemImage: "arrow.clockwise") { source.rescan() }
                        .help("Scan the source folder again")
                    Button("Choose Source Folder…", systemImage: "folder") { source.chooseFolder() }
                        .help("Choose Source Folder…")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if source.hasSource {
                VStack(spacing: 0) {
                    if let session = preview.session {
                        PlayerBar(player: preview.player, clock: preview.clock(atSeconds:),
                                  title: Format.sessionTitle(session.start, session.end),
                                  marked: source.trim(for: session).map { $0.start...$0.end }, onClose: preview.stop)
                        TrimBar(session: session, preview: preview)
                        if let error = preview.error {
                            Text(error).font(.caption).foregroundStyle(.red).padding(.bottom, 6)
                        }
                    }
                    DestinationBar(pending: pendingSessions, selectable: selectableSessions)
                }
            }
        }
        // A preview of something no longer on screen (recorder unplugged, regrouped, left the screen) stops.
        .onChange(of: source.sessions) {
            if let current = preview.session, !source.sessions.contains(where: { $0.id == current.id }) { preview.stop() }
        }
        .onDisappear { preview.stop() }
    }

    /// Selected sessions that still have something to import.
    private var pendingSessions: [RecordingSession] {
        source.selectedSessions.filter { session in
            guard let record = library.session(fingerprint: session.fingerprint) else { return true }
            return record.stage != .complete && !imports.isActive(record.id)
        }
    }

    /// Button-press fragments of a second or two. Hidden unless asked for, or relevant to an import.
    private func isFragment(_ session: RecordingSession) -> Bool {
        session.duration < SourceModel.fragmentDuration && session.recordings.count == 1
            && library.session(fingerprint: session.fingerprint) == nil
    }

    /// Visible sessions grouped by the day they started, newest day first, in time order within a day.
    private var days: [(day: Date, sessions: [RecordingSession])] {
        let visible = showFragments ? source.visibleSessions : source.visibleSessions.filter { !isFragment($0) }
        return Dictionary(grouping: visible) { Calendar.current.startOfDay(for: $0.start) }
            .map { (day: $0.key, sessions: $0.value) }
            .sorted { $0.day > $1.day }
    }

    /// Sessions currently listed that could still be imported.
    private var selectableSessions: [RecordingSession] {
        days.flatMap(\.sessions).filter { library.session(fingerprint: $0.fingerprint)?.stage != .complete }
    }

    private var sessionList: some View {
        let fragments = source.visibleSessions.filter(isFragment).count
        return List {
            if source.visibleSessions.isEmpty {
                Text(source.isScanning ? "Reading recordings…" : "No DJI recordings found here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(days, id: \.day) { day in
                Section(day.day.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                    ForEach(day.sessions) { session in
                        SessionRow(session: session, record: library.session(fingerprint: session.fingerprint),
                                   preview: preview, openSession: openSession)
                    }
                }
            }
            if fragments > 0 {
                Button(showFragments ? "Hide recordings shorter than 10 seconds"
                       : "Show \(fragments) \(fragments == 1 ? "recording" : "recordings") shorter than 10 seconds") {
                    showFragments.toggle()
                }
                .buttonStyle(.link)
                .font(.callout)
                .accessibilityIdentifier("toggle-fragments")
            }
            if !source.problems.isEmpty {
                Section("Unreadable Files") {
                    ForEach(source.problems) { problem in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(problem.filename).font(.callout.monospaced())
                            Text(problem.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay(alignment: .topTrailing) {
            if source.isScanning { ProgressView().controlSize(.small).padding(10) }
        }
    }
}

private struct SessionRow: View {
    let session: RecordingSession
    let record: ImportedSession?
    let preview: SessionPreview
    let openSession: (String) -> Void
    @Environment(SourceModel.self) private var source
    @Environment(ImportCoordinator.self) private var imports
    @State private var isExpanded = false

    private var progress: ImportProgress? { record.flatMap { imports.progress[$0.id] } }
    private var trim: Trim? { source.trim(for: session) }
    /// Stable suffix for accessibility identifiers (UI scripting and tests).
    private var tag: String { SessionFiles.basename(for: session.start, in: .current) }
    private var isLocked: Bool { record?.stage == .complete || progress != nil }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("Import", isOn: Binding(get: { source.isSelected(session) && record?.stage != .complete },
                                           set: { source.setSelected($0, session) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(isLocked)
                .accessibilityIdentifier("select-\(tag)")

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Format.sessionTitle(session.start(trimmedBy: trim), session.end(trimmedBy: trim)))
                        .fontWeight(.medium)
                    Spacer()
                    Text(Format.span(session.start(trimmedBy: trim), session.end(trimmedBy: trim)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button {
                        preview.play(session, at: preview.session?.id == session.id ? nil : trim?.start)
                    } label: {
                        Image(systemName: preview.isPlaying(session) ? "pause.circle.fill" : "play.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .help("Listen before importing: all of this session's files play as one recording")
                    .accessibilityLabel(preview.isPlaying(session) ? "Pause preview" : "Play preview")
                    .accessibilityIdentifier("preview-\(tag)")
                }
                HStack(spacing: 10) {
                    if let trim, record == nil {
                        Label("Trimmed", systemImage: "scissors")
                            .foregroundStyle(.orange)
                            .help("Imports \(Format.timeRange(session.start(trimmedBy: trim), session.end(trimmedBy: trim))) of \(Format.timeRange(session.start, session.end)). Play the session to change it.")
                    }
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            Text(Format.sourceFiles(session.recordings.count))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(Format.sourceFiles(session.recordings.count)), \(isExpanded ? "collapse" : "expand")")
                    .accessibilityIdentifier("files-\(tag)")

                    status
                    Spacer(minLength: 0)
                }
                .font(.callout)

                if let progress {
                    StageProgress(progress: progress).padding(.top, 2)
                }
                if isExpanded { chunks }
            }
        }
        .padding(.vertical, 4)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .contextMenu {
            Button("Merge with Previous") { source.mergeWithPrevious(session) }
                .disabled(source.previous(of: session) == nil || isLocked)
            if session.recordings.count > 1 {
                Menu("Split Before") {
                    ForEach(session.recordings.dropFirst()) { recording in
                        Button("\(recording.filename) (\(SessionTimeline.clock(recording.start, in: .current, seconds: false)))") {
                            source.split(session, before: recording)
                        }
                    }
                }
                .disabled(isLocked)
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let record {
            if progress != nil {
                Button("Stop") { imports.stop(record.id) }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("stop-\(tag)")
            } else if record.stage == .complete {
                Label(record.destinationPath == imports.destination?.path
                        ? "Imported" : "Imported in \(ImportCoordinator.name(of: record.destination))",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Open Transcript") { openSession(record.id) }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("open-\(tag)")
            } else {
                Label(record.failure ?? "Import not finished", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .help(record.failure ?? "")
                Button("Resume") { imports.resume(record.id) }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("resume-\(tag)")
            }
        } else if source.hasImportedChunks(session) {
            Text("Partly imported before")
                .foregroundStyle(.secondary)
                .help("Some of these files belong to an earlier import that was grouped differently.")
        } else if session.looksLikeContinuation, source.previous(of: session) != nil {
            Text("Starts right after the previous recording")
                .foregroundStyle(.secondary)
            Button("Merge") { source.mergeWithPrevious(session) }
                .buttonStyle(.link)
                .accessibilityIdentifier("merge-\(tag)")
        }
    }

    private var chunks: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(session.recordings.enumerated()), id: \.element.id) { index, recording in
                HStack(spacing: 8) {
                    Button("Play from here", systemImage: "play.fill") {
                        preview.play(session, at: SessionPreview.offset(of: recording, in: session))
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Play the session from the start of this file")
                    Text(recording.filename)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Format.timeRange(recording.start, recording.end))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if index == 0 {
                        if source.previous(of: session) != nil {
                            Button("Merge with Previous") { source.mergeWithPrevious(session) }
                                .disabled(isLocked)
                                .accessibilityIdentifier("merge-previous-\(tag)")
                        }
                    } else {
                        Button("Split Here") { source.split(session, before: recording) }
                            .disabled(isLocked)
                            .accessibilityIdentifier("split-\(recording.filename)")
                    }
                }
                .font(.callout)
                .buttonStyle(.link)
            }
            Text(session.recordings[0].format.summary)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
        }
        .padding(.top, 4)
        .padding(.leading, 14)
    }
}

/// Always-visible destination and the Import button.
private struct DestinationBar: View {
    let pending: [RecordingSession]
    let selectable: [RecordingSession]
    @Environment(ImportCoordinator.self) private var imports
    @Environment(SourceModel.self) private var source

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import into library")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let destination = imports.destination {
                        Label(Format.path(destination), systemImage: "books.vertical")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(destination.path)
                    } else {
                        Text("No library folder chosen")
                            .foregroundStyle(.secondary)
                    }
                    if let error = imports.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                if imports.libraries.isEmpty {
                    Button("Choose Library Folder…") { imports.addLibrary() }
                        .accessibilityIdentifier("choose-destination")
                } else {
                    Menu("Change") { LibraryMenuItems() }
                        .fixedSize()
                        .accessibilityIdentifier("choose-destination")
                }
                Spacer()
                Button(pending.isEmpty ? "Select All" : "Select None") {
                    let select = pending.isEmpty
                    for session in selectable { source.setSelected(select, session) }
                }
                .buttonStyle(.link)
                .disabled(selectable.isEmpty)
                .accessibilityIdentifier("select-all-none")
                Button(pending.isEmpty ? "Import" : "Import \(pending.count)") {
                    imports.importSessions(pending, trims: source.trims)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pending.isEmpty || imports.destination == nil)
                .accessibilityIdentifier("import")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }
}

/// Under the preview player: set where the import starts and ends from the playback position.
struct TrimBar: View {
    let session: RecordingSession
    let preview: SessionPreview
    @Environment(SourceModel.self) private var source

    var body: some View {
        let trim = source.trim(for: session)
        let kept = trim ?? Trim(start: 0, end: session.duration)
        HStack(spacing: 10) {
            Image(systemName: "scissors").foregroundStyle(.secondary)
            Text("Import from")
                .foregroundStyle(.secondary)
            Text(preview.clock(atSeconds: kept.start)).monospacedDigit()
            Button("Set Start") { source.setTrim(start: preview.player.currentSeconds, for: session) }
                .help("Start the import at the playback position")
                .accessibilityIdentifier("trim-start")
            Text("to").foregroundStyle(.secondary)
            Text(preview.clock(atSeconds: kept.end)).monospacedDigit()
            Button("Set End") { source.setTrim(end: preview.player.currentSeconds, for: session) }
                .help("End the import at the playback position")
                .accessibilityIdentifier("trim-end")
            if trim != nil {
                Button("Reset") { source.resetTrim(for: session) }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("trim-reset")
            }
            Spacer()
            Text(trim == nil ? "Whole recording" : "\(Format.duration(kept.duration)) of \(Format.duration(session.duration))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(.bar)
        .disabled(!preview.player.isAvailable)
    }
}
