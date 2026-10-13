import SwiftUI

/// Transcript viewer: clock time, speaker, text. Click an utterance to hear it.
struct TranscriptView: View {
    @State private var model: TranscriptModel
    @Environment(PeopleModel.self) private var people
    @State private var newPersonSpeaker: String?
    @State private var newPersonName = ""

    init(environment: AppEnvironment, sessionID: String) {
        _model = State(initialValue: environment.transcriptModel(for: sessionID))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.loadError {
                ContentUnavailableView("Transcript unavailable", systemImage: "doc.questionmark", description: Text(error))
            } else if model.isLoading && model.rows.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                notices
                speakerBar
                if model.rows.isEmpty {
                    ContentUnavailableView("No speech detected", systemImage: "waveform.slash",
                                           description: Text("The recording was transcribed, but it contains no speech."))
                } else {
                    transcriptList
                }
                PlayerBar(player: model.player, clock: model.clock(atSeconds:))
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Button("Open Markdown", systemImage: "doc.text") { open(\.markdown) }
                    .help("Open the Markdown transcript")
                Button("Show in Finder", systemImage: "folder") { reveal() }
                    .help("Show the exported files in Finder")
            }
        }
        .task { await model.load() }
        .onChange(of: people.people) { model.refreshMetadata() }
        .onDisappear { model.player.unload() }
        .alert("New Person", isPresented: .init(get: { newPersonSpeaker != nil }, set: { if !$0 { newPersonSpeaker = nil } })) {
            TextField("Name", text: $newPersonName)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                if let label = newPersonSpeaker, let person = people.create(named: newPersonName) {
                    Task { await model.setIdentity(.person(person.id), for: label) }
                }
            }
        } message: {
            Text("This speaker's voice in this recording is used to recognise them in future recordings.")
        }
    }

    private var zone: TimeZone { model.metadata.flatMap { TimeZone(identifier: $0.session.timeZone) } ?? .current }

    private var title: String {
        guard let session = model.metadata?.session else { return "Transcript" }
        return Format.sessionTitle(session.start, session.end, in: zone)
    }

    private var subtitle: String {
        guard let metadata = model.metadata else { return "" }
        let names = metadata.speakers.map(\.displayName).joined(separator: ", ")
        return [Format.span(metadata.session.start, metadata.session.end), names].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private var notices: some View {
        let messages = model.warnings + [model.actionError].compactMap { $0 }
        if !messages.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(messages, id: \.self) { Text($0) }
                }
                Spacer()
                if !model.warnings.isEmpty {
                    Button("Retry Speaker Analysis") { Task { await model.reanalyzeSpeakers() } }
                        .disabled(model.isReanalyzing)
                }
                if model.isReanalyzing { ProgressView().controlSize(.small) }
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.08))
            Divider()
        }
    }

    /// Everyone in the recording at a glance, each name a menu: the obvious place to say who is who.
    @ViewBuilder private var speakerBar: some View {
        if !model.speakers.isEmpty {
            HStack(spacing: 14) {
                Text("Speakers")
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(model.speakers, id: \.label) { speaker in
                            SpeakerMenu(label: speaker.label, speaker: speaker, people: people.people,
                                        decide: { decision in Task { await model.setIdentity(decision, for: speaker.label) } },
                                        newPerson: {
                                            newPersonName = ""
                                            newPersonSpeaker = speaker.label
                                        })
                                .disabled(model.isUpdatingSpeaker)
                                .accessibilityIdentifier("speaker-bar-\(speaker.label)")
                        }
                    }
                }
                Spacer(minLength: 8)
                if model.isUpdatingSpeaker {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Click a name to say who it is")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            Divider()
        }
    }

    private var transcriptList: some View {
        // List is table-backed and lazy: rows for multi-hour recordings are only built when scrolled to.
        let current = model.currentRowID
        return List(model.rows) { row in
            UtteranceRow(row: row, speaker: model.speaker(row.speaker), isCurrent: current == row.id,
                         isBusy: model.isUpdatingSpeaker, people: people.people,
                         play: { model.play(row) },
                         decide: { decision in Task { await model.setIdentity(decision, for: row.speaker) } },
                         newPerson: {
                             newPersonName = ""
                             newPersonSpeaker = row.speaker
                         })
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
    }

    private func open(_ file: KeyPath<SessionFiles, URL>) {
        if let files = model.files { NSWorkspace.shared.open(files[keyPath: file]) }
    }

    private func reveal() {
        if let files = model.files { NSWorkspace.shared.activateFileViewerSelecting([files.markdown]) }
    }
}

private struct UtteranceRow: View {
    let row: TranscriptRow
    let speaker: SpeakerEntry?
    let isCurrent: Bool
    let isBusy: Bool
    let people: [Person]
    let play: () -> Void
    let decide: (ManualDecision?) -> Void
    let newPerson: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.clock)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                SpeakerMenu(label: row.speaker, speaker: speaker, people: people, decide: decide, newPerson: newPerson)
                    .disabled(isBusy)
                    .accessibilityIdentifier("speaker-\(row.id)")
                Text(row.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("utterance-\(row.id)")
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(isCurrent ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: play)
        .accessibilityAction(named: "Play from here", play)
    }
}

/// The speaker label is the entry point for identity: a quiet menu, never a wizard.
private struct SpeakerMenu: View {
    let label: String
    let speaker: SpeakerEntry?
    let people: [Person]
    let decide: (ManualDecision?) -> Void
    let newPerson: () -> Void

    private var state: IdentityState { speaker?.state ?? .unidentified }
    private var isIdentified: Bool { speaker?.personID != nil }

    var body: some View {
        Menu {
            if let speaker {
                let reasons = IdentityExplanation.lines(for: speaker)
                if !reasons.isEmpty {
                    Section(isIdentified ? "Identified from" : "Not enough to identify") {
                        ForEach(reasons, id: \.self) { Text($0) }
                    }
                }
            }
            if state == .automatic {
                Button("Confirm Identity") { if let id = speaker?.personID { decide(.person(id)) } }
            }
            Section(isIdentified ? "Change to" : "Assign") {
                ForEach(people) { person in
                    Toggle(person.displayName, isOn: .init(get: { speaker?.personID == person.id },
                                                          set: { if $0 { decide(.person(person.id)) } }))
                }
                Button("New Person…", action: newPerson)
            }
            Section {
                if isIdentified {
                    Button("Remove Identity") { decide(nil) }
                }
                Toggle("Keep Unidentified", isOn: .init(get: { state == .manualUnidentified },
                                                       set: { decide($0 ? .unidentified : nil) }))
            }
        } label: {
            HStack(spacing: 3) {
                Text(speaker?.displayName ?? SpeakerEntry.defaultName(label))
                    .fontWeight(.semibold)
                // A visible "this is a menu" cue: the name alone does not look clickable.
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(isIdentified ? .primary : .secondary)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(isIdentified ? "Change or remove this speaker's identity" : "Say who this speaker is")
    }
}

/// Human-readable reasons behind a speaker's identity. Shown on demand; scores stay out of the transcript.
enum IdentityExplanation {
    static func lines(for speaker: SpeakerEntry) -> [String] {
        var lines: [String] = []
        let identified = speaker.personID != nil
        for evidence in speaker.evidence where evidence.applied == identified {
            let mark = evidence.applied ? "✓ " : ""
            switch evidence.source {
            case .manual:
                lines.append("\(mark)Assigned by you")
            case .voiceMatch:
                lines.append(evidence.applied
                    ? "\(mark)\(evidence.band == VoiceBand.strong.rawValue ? "Strong voice match" : "Voice profile")"
                    : "Voice resembles a known person, but not clearly enough")
            case .selfIdentification:
                lines.append("\(mark)Explicit introduction\(evidence.quote.map { ": “\($0)”" } ?? "")")
            case .transcriptContext:
                lines.append(evidence.applied
                    ? "\(mark)Named in conversation\(evidence.quote.map { ": “\($0)”" } ?? "")"
                    : "Possibly \(evidence.name ?? "named")\(evidence.quote.map { ": “\($0)”" } ?? "")")
            }
        }
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }
    }
}
