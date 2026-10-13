import XCTest
import AVFoundation
@testable import MicIngest

final class KeychainStoreTests: XCTestCase {
    // A separate service name keeps the test items apart from the app's real credentials.
    let keychain = KeychainStore(service: "dev.wsky.MicIngest.tests")
    let account = "unit-test-\(UUID().uuidString)"

    override func tearDown() { try? keychain.delete(account) }

    func testStoreRetrieveReplaceDelete() throws {
        XCTAssertNil(try keychain.get(account), "missing credentials are nil, not an error")
        try keychain.set("first-secret", for: account)
        XCTAssertEqual(try keychain.get(account), "first-secret")
        try keychain.set("  second-secret\n", for: account)
        XCTAssertEqual(try keychain.get(account), "second-secret", "replaced and trimmed")
        try keychain.delete(account)
        XCTAssertNil(try keychain.get(account))
        XCTAssertNoThrow(try keychain.delete(account), "deleting a missing item is fine")
    }

    func testEmptyValueRemovesTheItem() throws {
        try keychain.set("secret", for: account)
        try keychain.set("   ", for: account)
        XCTAssertNil(try keychain.get(account))
    }

    func testErrorsDoNotContainTheSecret() {
        let description = KeychainError.unexpectedStatus(errSecAuthFailed).localizedDescription
        XCTAssertTrue(description.contains("\(errSecAuthFailed)"))
        let serviceError = ServiceError(service: "AssemblyAI", kind: .unauthorized, statusCode: 401)
        XCTAssertEqual(serviceError.localizedDescription, "AssemblyAI rejected the API key. Check it in Settings.")
        XCTAssertEqual(ServiceError(service: "AssemblyAI", kind: .missingKey).localizedDescription,
                       "AssemblyAI API key is missing. Add it in Settings.")
    }

    func testSettingsNeverHoldCredentials() {
        let name = "MicIngestTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.groqModel = "some/model"
        settings.transcriptionPrompt = "context"
        settings.voiceThresholds = VoiceThresholds(strong: 0.7, enroll: 0.8, borderline: 0.5, margin: 0.1)
        XCTAssertEqual(settings.groqModel, "some/model")
        XCTAssertEqual(settings.voiceThresholds.strong, 0.7)
        let keys = Set(defaults.persistentDomain(forName: name)?.keys.map { $0 } ?? [])
        XCTAssertEqual(keys, ["groqModel", "transcriptionPrompt", "voiceThresholds"])

        // Several libraries are remembered in order, including one whose folder is currently unreachable.
        let reachable = FileManager.default.temporaryDirectory, offline = URL(fileURLWithPath: "/Volumes/NotMounted/Work Library", isDirectory: true)
        settings.libraries = [reachable, offline]
        XCTAssertEqual(settings.libraries.map(\.lastPathComponent), [reachable.lastPathComponent, "Work Library"])
        settings.libraries = []
        settings.groqModel = "  "
        XCTAssertEqual(settings.groqModel, AppConfig.Groq.defaultModel, "blank falls back to the default model")
    }
}

/// Runs the bundled Core ML embedding model on synthesized speech (macOS system voices).
/// Different voices must be told apart; the same voice saying different things must match.
final class SpeakerEmbedderTests: XCTestCase {
    static var folder: URL!

    override class func setUp() {
        folder = try? temporaryDirectory()
    }

    override class func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// Synthesizes `text` with a system voice into a 16 kHz mono WAV. Skips the test if unavailable.
    private func speak(_ text: String, voice: String, name: String) throws -> URL {
        let url = Self.folder.appendingPathComponent("\(name).wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", url.path, "--data-format=LEI16@16000", text]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, (try? AVAudioFile(forReading: url).length) ?? 0 > 16_000 else {
            throw XCTSkip("System voice \(voice) is not available")
        }
        return url
    }

    private func embedding(_ url: URL, embedder: SpeakerEmbedder) async throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let milliseconds = Int(Double(file.length) / file.fileFormat.sampleRate * 1000)
        let excerpt = SpeechExcerpt(startMs: 0, endMs: min(milliseconds, 10_000))
        let embedding = try await embedder.clusterEmbedding(audio: url, excerpts: [excerpt])
        return try XCTUnwrap(embedding)
    }

    func testSameVoiceMatchesAndDifferentVoicesDoNot() async throws {
        let first = "Ich glaube, wir sollten morgen etwas früher losfahren, sonst stehen wir wieder ewig im Stau."
        let second = "Hast du eigentlich schon die Unterlagen für das Treffen nächste Woche durchgelesen oder noch nicht?"
        let annaOne = try speak(first, voice: "Anna", name: "anna1")
        let annaTwo = try speak(second, voice: "Anna", name: "anna2")
        let other = try speak(first, voice: "Eddy (German (Germany))", name: "eddy1")

        let embedder = SpeakerEmbedder()
        let a1 = try await embedding(annaOne, embedder: embedder)
        let a2 = try await embedding(annaTwo, embedder: embedder)
        let b1 = try await embedding(other, embedder: embedder)

        XCTAssertEqual(a1.count, SpeakerEmbedder.dimension)
        XCTAssertEqual(VoiceMatcher.cosine(a1, a1), 1, accuracy: 0.0001)
        let same = VoiceMatcher.cosine(a1, a2), different = VoiceMatcher.cosine(a1, b1)
        XCTAssertGreaterThan(same, VoiceThresholds.default.strong, "same voice, different sentence")
        XCTAssertLessThan(different, VoiceThresholds.default.borderline, "different voice, same sentence")

        // The matcher draws the same conclusion from a stored profile.
        let match = VoiceMatcher.match(a2, profiles: ["anna": [a1], "eddy": [b1]], thresholds: .default)
        XCTAssertEqual(match.best?.personID, "anna")
        XCTAssertEqual(match.band, .strong)
        XCTAssertEqual(VoiceMatcher.match(b1, profiles: ["anna": [a1]], thresholds: .default).band, .unknown)
    }

    func testReadsExcerptAs16kHzMonoFromHighRateStereoAudio() throws {
        let url = Self.folder.appendingPathComponent("stereo48k.wav")
        try writeWAV(to: url, seconds: 4, sampleRate: 48_000, bitDepth: 24, channels: 2)
        let samples = try SpeakerEmbedder.read(try AVAudioFile(forReading: url), excerpt: SpeechExcerpt(startMs: 1000, endMs: 3000))
        XCTAssertEqual(Double(samples.count), 32_000, accuracy: 400)
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.1)
        // Out-of-range excerpts are empty rather than a crash.
        XCTAssertTrue(try SpeakerEmbedder.read(try AVAudioFile(forReading: url), excerpt: SpeechExcerpt(startMs: 9000, endMs: 12_000)).isEmpty)
    }

    func testVoiceProfileStorageAndEviction() throws {
        let database = try AppDatabase.inMemory()
        let person = try database.createPerson(named: "Sam")
        func sample(_ session: String, _ provenance: EmbeddingProvenance, daysAgo: Double) -> VoiceSample {
            VoiceSample(id: UUID().uuidString, personID: person.id, modelVersion: SpeakerEmbedder.modelVersion,
                        embedding: VoiceSample.data([0.6, 0.8, 0, 0]), provenance: provenance, sessionID: session,
                        speakerLabel: "A", speechSeconds: 30, createdAt: Date().addingTimeInterval(-daysAgo * 86_400))
        }
        try database.replaceVoiceSample(sessionID: "s1", speakerLabel: "A", with: sample("s1", .manualConfirmation, daysAgo: 9), limitPerPerson: 3)
        try database.replaceVoiceSample(sessionID: "s2", speakerLabel: "A", with: sample("s2", .highConfidenceVoiceMatch, daysAgo: 8), limitPerPerson: 3)
        try database.replaceVoiceSample(sessionID: "s3", speakerLabel: "A", with: sample("s3", .highConfidenceVoiceMatch, daysAgo: 7), limitPerPerson: 3)
        XCTAssertEqual(try database.voiceSamples(modelVersion: SpeakerEmbedder.modelVersion).first?.vector, [0.6, 0.8, 0, 0])

        // Re-analysing a session replaces its own contribution instead of adding another.
        try database.replaceVoiceSample(sessionID: "s3", speakerLabel: "A", with: sample("s3", .highConfidenceVoiceMatch, daysAgo: 1), limitPerPerson: 3)
        XCTAssertEqual(try database.voiceSampleCounts()[person.id], 3)

        // Over the limit: the oldest automatic sample goes, the manual one stays.
        try database.replaceVoiceSample(sessionID: "s4", speakerLabel: "A", with: sample("s4", .explicitSelfIdentification, daysAgo: 0), limitPerPerson: 3)
        let remaining = try database.voiceSamples(modelVersion: SpeakerEmbedder.modelVersion)
        XCTAssertEqual(Set(remaining.map(\.sessionID)), ["s1", "s3", "s4"])

        // Removing an identity removes that session's sample; samples of other model versions are ignored.
        try database.replaceVoiceSample(sessionID: "s4", speakerLabel: "A", with: nil, limitPerPerson: 3)
        XCTAssertEqual(try database.voiceSampleCounts()[person.id], 2)
        XCTAssertTrue(try database.voiceSamples(modelVersion: "another-model").isEmpty)

        // Voice data can be removed without deleting the person; deleting the person removes everything.
        try database.deleteVoiceSamples(personID: person.id)
        XCTAssertNil(try database.voiceSampleCounts()[person.id])
        XCTAssertEqual(try database.people().count, 1)
        try database.replaceVoiceSample(sessionID: "s1", speakerLabel: "A", with: sample("s1", .manualConfirmation, daysAgo: 0), limitPerPerson: 3)
        try database.deletePerson(id: person.id)
        XCTAssertTrue(try database.voiceSamples(modelVersion: SpeakerEmbedder.modelVersion).isEmpty)
    }
}
