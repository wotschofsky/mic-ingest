import SwiftUI

struct SettingsView: View {
    let environment: AppEnvironment

    var body: some View {
        TabView {
            Tab("Integrations", systemImage: "key") { IntegrationsSettings(environment: environment) }
            Tab("Transcription", systemImage: "waveform") {
                TranscriptionSettings(settings: environment.settings, recorderClockChanged: { environment.source.rescan(resetSelection: true) })
            }
            Tab("Speakers", systemImage: "person.2") { SpeakerSettings(library: environment.imports.destination) }
            Tab("Advanced", systemImage: "gearshape.2") { AdvancedSettings(environment: environment) }
        }
        .frame(width: 560, height: 420)
    }
}

// MARK: - Integrations

private struct IntegrationsSettings: View {
    let environment: AppEnvironment

    var body: some View {
        Form {
            APIKeyRow(title: "AssemblyAI", detail: "Receives the merged audio for transcription and diarization.",
                      account: .assemblyAI, keychain: environment.keychain) { try await environment.assemblyAI.verifyKey() }
            APIKeyRow(title: "Groq", detail: "Receives transcript text to infer speaker names. Optional.",
                      account: .groq, keychain: environment.keychain) { try await environment.groq.verifyKey() }
            Section {
                Text("API keys are stored in the macOS Keychain. Voice profiles are never sent to either service; they are kept in each library folder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct APIKeyRow: View {
    enum Status: Equatable { case unknown, missing, saved, testing, ok, failed(String) }

    let title: String
    let detail: String
    let account: KeychainStore.Account
    let keychain: KeychainStore
    let verify: () async throws -> Void
    @State private var key = ""
    @State private var status = Status.unknown

    var body: some View {
        Section {
            SecureField("API key", text: $key)
                .onSubmit(save)
            HStack {
                statusLabel
                Spacer()
                Button("Test", action: test).disabled(key.isEmpty || status == .testing)
                Button("Save", action: save)
            }
        } header: {
            Text(title)
        } footer: {
            Footnote(detail)
        }
        .onAppear {
            key = keychain.get(account) ?? ""
            status = key.isEmpty ? .missing : .saved
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch status {
        case .unknown: EmptyView()
        case .missing: Label("No key stored", systemImage: "minus.circle").foregroundStyle(.secondary)
        case .saved: Label("Stored in Keychain", systemImage: "lock").foregroundStyle(.secondary)
        case .testing: ProgressView().controlSize(.small)
        case .ok: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Label(message, systemImage: "xmark.circle").foregroundStyle(.red).lineLimit(2)
        }
    }

    private func save() {
        do {
            try keychain.set(key, for: account)
            status = key.trimmingCharacters(in: .whitespaces).isEmpty ? .missing : .saved
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func test() {
        save()
        guard status == .saved else { return }
        status = .testing
        Task {
            do {
                try await verify()
                status = .ok
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Transcription

private struct TranscriptionSettings: View {
    let settings: AppSettings
    let recorderClockChanged: () -> Void
    @State private var prompt = ""
    /// Seconds from UTC of the recorder's clock; nil means "same as this Mac".
    @State private var recorderOffset: Int?

    var body: some View {
        Form {
            Section {
                Picker("Recorder clock", selection: $recorderOffset) {
                    Text("Same as this Mac").tag(Int?.none)
                    Divider()
                    ForEach(-12...14, id: \.self) { hours in
                        Text(Format.utcOffset(TimeZone(secondsFromGMT: hours * 3600)!) + (hours == 8 ? " (China, DJI factory setting)" : ""))
                            .tag(Int?.some(hours * 3600))
                    }
                }
                .onChange(of: recorderOffset) {
                    let zone = recorderOffset.flatMap(TimeZone.init(secondsFromGMT:))
                    guard zone != settings.recorderTimeZone else { return }
                    settings.recorderTimeZone = zone
                    recorderClockChanged()
                }
            } header: {
                Text("Recorder")
            } footer: {
                Footnote("The recorder stamps files with its own clock and stores no time zone. If its clock is not set to your local time, choose the zone it runs in and recording times are converted to local time. Applies to new imports.")
            }
            Section("Model") {
                LabeledContent("AssemblyAI model", value: AppConfig.AssemblyAI.speechModels.joined(separator: ", "))
                LabeledContent("Languages", value: "German and English, with code-switching")
                LabeledContent("Speaker diarization", value: "On, speaker count detected automatically")
            }
            Section {
                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(minHeight: 90)
                    .onChange(of: prompt) { settings.transcriptionPrompt = prompt }
                HStack {
                    Spacer()
                    Button("Reset to Default") { prompt = AppConfig.AssemblyAI.defaultPrompt }
                        .disabled(prompt == AppConfig.AssemblyAI.defaultPrompt)
                }
            } header: {
                Text("Context")
            } footer: {
                Footnote("Describes what the recordings contain. It helps the model with names and vocabulary; it is not an instruction and the speech is never summarised or rewritten.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            prompt = settings.transcriptionPrompt
            recorderOffset = settings.recorderTimeZone?.secondsFromGMT()
        }
    }
}

// MARK: - Speakers

private struct SpeakerSettings: View {
    let library: URL?
    @Environment(PeopleModel.self) private var people
    @State private var renaming: Person?
    @State private var newName = ""
    @State private var deleting: Person?

    var body: some View {
        Form {
            Section("Voice Recognition") {
                LabeledContent("Embedding model", value: SpeakerEmbedder.modelName)
                LabeledContent("Version", value: SpeakerEmbedder.modelVersion)
                Text("Runs on this Mac. Voice profiles are kept in the library folder (Data/People.json) and never sent to AssemblyAI or Groq. Model by pyannote, WeSpeaker and Fluid Inference, CC-BY-4.0.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section(library.map { "People in “\(ImportCoordinator.name(of: $0))”" } ?? "Known People") {
                if people.people.isEmpty {
                    Text("People appear here once you name a speaker in a transcript. Each library keeps its own people and voice profiles.")
                        .foregroundStyle(.secondary)
                }
                ForEach(people.people) { person in
                    let samples = people.sampleCounts[person.id] ?? 0
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(person.displayName)
                            Text(samples == 0 ? "No voice profile" : "\(samples) voice sample\(samples == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu("Edit") {
                            Button("Rename…") {
                                newName = person.displayName
                                renaming = person
                            }
                            Button("Remove Voice Data") { people.removeVoiceData(person) }
                                .disabled(samples == 0)
                            Divider()
                            Button("Delete Person…", role: .destructive) { deleting = person }
                        }
                        .fixedSize()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Rename Person", isPresented: .init(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { if let renaming { people.rename(renaming, to: newName) } }
        } message: {
            Text("Transcripts that mention this person are updated.")
        }
        .confirmationDialog("Delete \(deleting?.displayName ?? "this person")?",
                            isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { person in
            Button("Delete Person and Voice Data", role: .destructive) { people.delete(person) }
        } message: { _ in
            Text("Their voice profile is removed and their speakers become unidentified again in all transcripts.")
        }
    }
}

// MARK: - Advanced

private struct AdvancedSettings: View {
    let environment: AppEnvironment
    @State private var groqModel = ""
    @State private var thresholds = VoiceThresholds.default

    private var settings: AppSettings { environment.settings }

    var body: some View {
        Form {
            Section {
                TextField("Groq model", text: $groqModel, prompt: Text(AppConfig.Groq.defaultModel))
                    .onChange(of: groqModel) { settings.groqModel = groqModel }
            } footer: {
                Footnote("Must support strict JSON Schema structured output. Default: \(AppConfig.Groq.defaultModel).")
            }
            Section {
                ThresholdRow(title: "Strong match", value: $thresholds.strong)
                ThresholdRow(title: "Add to voice profile", value: $thresholds.enroll)
                ThresholdRow(title: "Ambiguous above", value: $thresholds.borderline)
                ThresholdRow(title: "Lead over runner-up", value: $thresholds.margin, range: 0...0.4)
                HStack {
                    Spacer()
                    Button("Reset to Defaults") { thresholds = .default }
                        .disabled(thresholds == .default)
                }
            } header: {
                Text("Voice Matching")
            } footer: {
                Footnote("Cosine similarity between a speaker and a stored voice profile. Higher values mean fewer but safer automatic identifications.")
            }
            .onChange(of: thresholds) { settings.voiceThresholds = thresholds }
            Section("Diagnostics") {
                if let url = environment.database.fileURL {
                    LabeledContent("Database") {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
                LabeledContent("Logs", value: "Console.app, subsystem \(AppConfig.logSubsystem)")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            groqModel = settings.groqModel
            thresholds = settings.voiceThresholds
        }
    }
}

private struct ThresholdRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0.2...0.95

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: 0.01)
                    .frame(width: 180)
                Text(value, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }
}

/// Explanatory text under a settings section.
private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
