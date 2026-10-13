import SwiftUI

enum SidebarItem: Hashable {
    case importer
    case session(String)
}

struct RootView: View {
    let environment: AppEnvironment
    @Environment(LibraryModel.self) private var library
    @Environment(ImportCoordinator.self) private var imports
    @Environment(SourceModel.self) private var source
    @Environment(PeopleModel.self) private var people
    @State private var selection: SidebarItem? = .importer
    @State private var sessionToTrash: ImportedSession?
    @State private var trashError: String?

    /// Transcripts of the current library, newest first.
    private var sessions: [ImportedSession] {
        guard let current = imports.destination else { return library.sessions }
        return library.sessions.filter { $0.destinationPath == current.path }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Import", systemImage: "square.and.arrow.down")
                    .tag(SidebarItem.importer)
                if !sessions.isEmpty {
                    Section("Transcripts") {
                        ForEach(sessions) { session in
                            SidebarSessionRow(session: session, progress: imports.progress[session.id])
                                .tag(SidebarItem.session(session.id))
                                .contextMenu {
                                    Button("Show in Finder") { reveal(session) }
                                    Divider()
                                    Button("Move to Trash…", role: .destructive) { sessionToTrash = session }
                                        .disabled(imports.isActive(session.id))
                                }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { LibrarySwitcher() }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            switch selection {
            case .session(let id):
                SessionDetailView(environment: environment, sessionID: id)
                    .id(id)
            default:
                ImportView(openSession: open)
            }
        }
        .task { source.start(initialFolder: environment.initialSource) }
        .onChange(of: library.sessions) { source.refreshImported() }
        .onChange(of: imports.destination) {
            // Another library: its own people, and no transcript of the previous one left open.
            people.reload()
            if case .session(let id) = selection, !sessions.contains(where: { $0.id == id }) { selection = .importer }
        }
        .confirmationDialog(
            "Move this recording to the Trash?", isPresented: .init(get: { sessionToTrash != nil }, set: { if !$0 { sessionToTrash = nil } }),
            presenting: sessionToTrash
        ) { session in
            Button("Move to Trash", role: .destructive) {
                if selection == .session(session.id) { selection = .importer }
                do { try SessionStore(database: environment.database).trash(session) } catch { trashError = error.localizedDescription }
            }
        } message: { _ in
            Text("Its transcript, audio and data files are moved from the library folder to the Trash. Nothing on the recorder is touched.")
        }
        .alert("Could not move the recording to the Trash", isPresented: .init(get: { trashError != nil }, set: { if !$0 { trashError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(trashError ?? "")
        }
    }

    /// Opens a transcript, switching to the library it lives in first if that is not the current one.
    private func open(_ sessionID: String) {
        if let session = library.session(id: sessionID), session.destinationPath != imports.destination?.path {
            imports.select(session.destination)
        }
        selection = .session(sessionID)
    }

    private func reveal(_ session: ImportedSession) {
        let files = SessionStore(database: environment.database).files(for: session)
        let existing = [files.markdown, files.metadata].filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.isEmpty {
            NSWorkspace.shared.open(files.folder)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([existing[0]])
        }
    }
}

/// The current library's name at the top of the sidebar; a menu to switch, add, reload or remove libraries.
private struct LibrarySwitcher: View {
    @Environment(ImportCoordinator.self) private var imports

    var body: some View {
        Menu {
            LibraryMenuItems()
        } label: {
            Label(imports.destination.map(ImportCoordinator.name(of:)) ?? "Choose Library…", systemImage: "books.vertical")
                .fontWeight(.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .help("Switch between libraries, add one, or reload the current one")
        .accessibilityIdentifier("library-switcher")
    }
}

/// Menu content shared by the sidebar switcher and the import bar.
struct LibraryMenuItems: View {
    @Environment(ImportCoordinator.self) private var imports

    var body: some View {
        ForEach(imports.libraries, id: \.path) { library in
            Toggle(ImportCoordinator.name(of: library),
                   isOn: .init(get: { imports.destination?.path == library.path }, set: { if $0 { imports.select(library) } }))
        }
        Divider()
        Button("Add Library Folder…") { imports.addLibrary() }
        if let current = imports.destination {
            Button("Reload from Folder") { imports.reloadLibrary() }
            Button("Show in Finder") { NSWorkspace.shared.open(current) }
            Divider()
            // The folder and everything in it stay on disk; only the app stops listing it.
            Button("Remove “\(ImportCoordinator.name(of: current))” from \(AppConfig.appName)") { imports.remove(current) }
                .disabled(imports.isBusy)
        }
    }
}

private struct SidebarSessionRow: View {
    let session: ImportedSession
    let progress: ImportProgress?

    private var zone: TimeZone { TimeZone(identifier: session.timeZone) ?? .current }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(Format.day(session.start, in: zone)) · \(SessionTimeline.clock(session.start, in: zone, seconds: false))")
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if progress != nil {
                ProgressView().controlSize(.small)
            } else if session.stage == .failed {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .help(session.failure ?? "Import failed")
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if let progress { return progress.stage.title }
        if session.stage == .failed { return "Not finished" }
        return "\(Format.span(session.start, session.end)) · \(session.transmitter)"
    }
}

/// Detail for a library entry: the transcript once it exists, otherwise the import's status.
private struct SessionDetailView: View {
    let environment: AppEnvironment
    let sessionID: String
    @Environment(LibraryModel.self) private var library
    @Environment(ImportCoordinator.self) private var imports

    var body: some View {
        if let session = library.session(id: sessionID) {
            if session.stage == .complete {
                TranscriptView(environment: environment, sessionID: sessionID)
            } else {
                ImportStatusView(session: session, progress: imports.progress[session.id],
                                 resume: { imports.resume(session.id) }, stop: { imports.stop(session.id) })
            }
        } else {
            ContentUnavailableView("Recording not found", systemImage: "questionmark.folder")
        }
    }
}

private struct ImportStatusView: View {
    let session: ImportedSession
    let progress: ImportProgress?
    let resume: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if let progress {
                StageProgress(progress: progress)
                    .frame(width: 280)
                Button("Stop", action: stop)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(session.lastActiveStage.map { "Stopped while \($0.title.lowercased())" } ?? "Import not finished")
                    .font(.headline)
                Text(session.failure ?? "")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 440)
                Button("Resume Import", action: resume)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(Format.sessionTitle(session.start, session.end, in: TimeZone(identifier: session.timeZone) ?? .current))
    }
}

/// Stage name plus a bar: determinate only where a real fraction exists (merging, uploading).
struct StageProgress: View {
    let progress: ImportProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(progress.stage.title)
                if let remaining = progress.remaining {
                    Text("· \(Format.remaining(remaining))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let fraction = progress.fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            if let fraction = progress.fraction {
                ProgressView(value: min(max(fraction, 0), 1))
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
    }
}
