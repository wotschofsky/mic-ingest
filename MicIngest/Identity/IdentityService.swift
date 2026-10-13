import Foundation

/// Orchestrates speaker identity for a session: local voice embeddings, voice matching, transcript
/// inference via Groq, the resolver, and conservative profile enrolment. Nothing here can fail a
/// transcription: problems are reported as warnings and speakers simply stay unidentified.
struct IdentityService {
    static let nameInferenceFailedWarning = "Speaker identity inference failed. Transcript is still available."
    static let voiceFailedWarning = "Voice identification failed. Transcript is still available."
    /// Upper bound on stored samples per person and embedding model.
    static let profileLimit = 24

    var database: AppDatabase
    var embedder: SpeakerEmbedder
    var groq: GroqClient
    var settings: AppSettings
    var selector = ExcerptSelector()

    /// Fewer excerpts than this are enough to compare a voice, but not to add an automatic match to a profile.
    static let minimumExcerptsForAutomaticEnrollment = 4

    private struct Cluster {
        var embedding: [Float]
        var speechSeconds: Double
        var excerptCount: Int
    }

    private func cluster(for label: String, transcript: Transcript, audio: URL) async throws -> Cluster? {
        let excerpts = selector.excerpts(for: label, in: transcript)
        guard !excerpts.isEmpty, let embedding = try await embedder.clusterEmbedding(audio: audio, excerpts: excerpts) else { return nil }
        return Cluster(embedding: embedding, speechSeconds: excerpts.reduce(0) { $0 + $1.seconds }, excerptCount: excerpts.count)
    }

    private func enroll(_ cluster: Cluster?, personID: String?, provenance: EmbeddingProvenance?, sessionID: String, label: String) {
        var sample: VoiceSample?
        if let cluster, let personID, let provenance,
           provenance != .highConfidenceVoiceMatch || cluster.excerptCount >= Self.minimumExcerptsForAutomaticEnrollment {
            sample = VoiceSample(id: UUID().uuidString, personID: personID, modelVersion: SpeakerEmbedder.modelVersion,
                                 embedding: VoiceSample.data(cluster.embedding), provenance: provenance, sessionID: sessionID,
                                 speakerLabel: label, speechSeconds: cluster.speechSeconds, createdAt: Date())
            Log.identity.info("Enrolling voice sample (\(provenance.rawValue, privacy: .public)) from speaker \(label, privacy: .public)")
        }
        do {
            try database.replaceVoiceSample(sessionID: sessionID, speakerLabel: label, with: sample, limitPerPerson: Self.profileLimit)
        } catch {
            Log.identity.error("Could not update voice profile: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Voice samples of everyone, per person, excluding what this session itself contributed
    /// (a session must never confirm its own earlier guess).
    private func profiles(excluding sessionID: String, library: String?) -> [String: [[Float]]] {
        let samples = (try? database.voiceSamples(modelVersion: SpeakerEmbedder.modelVersion, library: library)) ?? []
        return Dictionary(grouping: samples.filter { $0.sessionID != sessionID }, by: \.personID).mapValues { $0.map(\.vector) }
    }

    // MARK: Automatic analysis

    /// Resolves every diarized speaker and returns the updated metadata plus any warnings.
    /// Existing manual decisions are kept. Only people of `library` (the session's library folder)
    /// are considered, and new people are created in it.
    func analyze(transcript: Transcript, metadata: SessionMetadata, audio: URL?, library: String? = nil) async -> (SessionMetadata, [String]) {
        var metadata = metadata
        var warnings: [String] = []
        let sessionID = metadata.session.id
        let thresholds = settings.voiceThresholds
        let labels = transcript.speakers

        var manual: [String: ManualDecision] = [:]
        for entry in metadata.speakers {
            if entry.state == .manual, let personID = entry.personID { manual[entry.label] = .person(personID) }
            if entry.state == .manualUnidentified { manual[entry.label] = .unidentified }
        }

        // 1. Local voice embeddings and matching.
        var clusters: [String: Cluster] = [:]
        var voice = SessionMetadata.IdentityInference.Voice(
            model: SpeakerEmbedder.modelName, version: SpeakerEmbedder.modelVersion, dimension: SpeakerEmbedder.dimension,
            status: "ok", error: nil, thresholds: thresholds)
        if let audio {
            do {
                for label in labels {
                    try Task.checkCancellation()
                    clusters[label] = try await cluster(for: label, transcript: transcript, audio: audio)
                }
            } catch {
                voice.status = "failed"
                voice.error = error.localizedDescription
                warnings.append(Self.voiceFailedWarning)
                clusters = [:]
                Log.identity.error("Voice embedding failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            voice.status = "skipped"
        }
        let profiles = profiles(excluding: sessionID, library: library)
        let matches = clusters.mapValues { VoiceMatcher.match($0.embedding, profiles: profiles, thresholds: thresholds) }

        // 2. Names from the transcript text (Groq). Optional: without a key it is skipped.
        var people = (try? database.people(in: library)) ?? []
        var findings: [String: NameFinding] = [:]
        let model = settings.groqModel
        var llm = SessionMetadata.IdentityInference.LLM(model: model, status: "ok", error: nil)
        if transcript.utterances.isEmpty {
            llm.status = "skipped"
        } else {
            do {
                findings = try await SpeakerNameInference.infer(
                    transcript: transcript, knownNames: people.map(\.displayName), model: model, client: groq)
            } catch let error as ServiceError where error.kind == .missingKey {
                llm.status = "skipped"
                llm.error = error.localizedDescription
            } catch {
                llm.status = "failed"
                llm.error = error.localizedDescription
                warnings.append(Self.nameInferenceFailedWarning)
                Log.identity.error("Name inference failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // 3. Resolve, create people where someone explicitly introduced themselves, enrol conservatively.
        let starts = Dictionary(uniqueKeysWithValues: transcript.utterances.map { ($0.index, $0.startMs) })
        var entries: [SpeakerEntry] = []
        for label in labels {
            let resolver = IdentityResolver(people: people, peopleWithVoiceProfile: Set(profiles.keys), thresholds: thresholds)
            var resolution = resolver.resolve(ResolverInput(
                label: label, manual: manual[label], voice: matches[label], finding: findings[label], utteranceStartMs: starts))

            var personID: String?
            switch resolution.outcome {
            case .person(let id):
                personID = people.contains { $0.id == id } ? id : nil
            case .newPerson(let name):
                if let created = try? database.createPerson(named: name, library: library ?? "") {
                    people.append(created)
                    personID = created.id
                    for index in resolution.evidence.indices where resolution.evidence[index].applied {
                        resolution.evidence[index].personID = created.id
                    }
                }
            case .unidentified:
                break
            }
            if personID == nil, resolution.state == .automatic || resolution.state == .manual {
                // The person no longer exists (or could not be created): fall back to unidentified.
                resolution.state = .unidentified
                resolution.confidence = nil
            }
            enroll(clusters[label], personID: personID, provenance: resolution.enrollment, sessionID: sessionID, label: label)

            let name = personID.flatMap { id in people.first { $0.id == id }?.displayName }
            entries.append(SpeakerEntry(
                label: label, personID: personID, displayName: name ?? SpeakerEntry.defaultName(label),
                state: resolution.state, confidence: resolution.confidence, evidence: resolution.evidence,
                utteranceCount: transcript.utterances.filter { $0.speaker == label }.count,
                speechSeconds: (transcript.speechSeconds(of: label) * 10).rounded() / 10))
        }
        metadata.speakers = entries
        metadata.identityInference = .init(llm: llm, voice: voice)
        Log.identity.info("Resolved \(entries.filter { $0.personID != nil }.count) of \(entries.count) speakers")
        return (metadata, warnings)
    }

    // MARK: Manual decisions

    /// Applies the user's decision for one speaker. `nil` removes the identity and hands the speaker
    /// back to automation; `.unidentified` pins it as unnamed. A manual assignment is high-trust
    /// evidence and adds this cluster's voice to the person's profile.
    func apply(_ decision: ManualDecision?, to label: String, transcript: Transcript, metadata: SessionMetadata, audio: URL?) async -> SessionMetadata {
        var metadata = metadata
        guard let index = metadata.speakers.firstIndex(where: { $0.label == label }) else { return metadata }
        var entry = metadata.speakers[index]
        entry.evidence.removeAll { $0.source == .manual }
        for i in entry.evidence.indices { entry.evidence[i].applied = false }
        entry.confidence = nil

        var enrolledPerson: String?
        switch decision {
        case .person(let id):
            guard let person = try? database.person(id: id) else { return metadata }
            entry.personID = person.id
            entry.displayName = person.displayName
            entry.state = .manual
            entry.evidence.insert(IdentityEvidence(source: .manual, applied: true, personID: person.id), at: 0)
            enrolledPerson = person.id
        case .unidentified:
            entry.personID = nil
            entry.displayName = SpeakerEntry.defaultName(label)
            entry.state = .manualUnidentified
        case nil:
            entry.personID = nil
            entry.displayName = SpeakerEntry.defaultName(label)
            entry.state = .unidentified
        }
        metadata.speakers[index] = entry

        var cluster: Cluster?
        if enrolledPerson != nil, let audio {
            cluster = try? await self.cluster(for: label, transcript: transcript, audio: audio)
        }
        enroll(cluster, personID: enrolledPerson, provenance: .manualConfirmation, sessionID: metadata.session.id, label: label)
        return metadata
    }

    /// Reflects a renamed or deleted person in a session's speaker list. Returns nil if nothing changed.
    func refreshed(_ metadata: SessionMetadata, people: [Person]) -> SessionMetadata? {
        var metadata = metadata
        var changed = false
        for index in metadata.speakers.indices {
            guard let personID = metadata.speakers[index].personID else { continue }
            if let person = people.first(where: { $0.id == personID }) {
                if metadata.speakers[index].displayName != person.displayName {
                    metadata.speakers[index].displayName = person.displayName
                    changed = true
                }
            } else {
                let label = metadata.speakers[index].label
                metadata.speakers[index].personID = nil
                metadata.speakers[index].displayName = SpeakerEntry.defaultName(label)
                metadata.speakers[index].state = .unidentified
                metadata.speakers[index].confidence = nil
                for i in metadata.speakers[index].evidence.indices { metadata.speakers[index].evidence[i].applied = false }
                changed = true
            }
        }
        return changed ? metadata : nil
    }
}
