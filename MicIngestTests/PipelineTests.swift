import XCTest
import AVFoundation
import GRDB
@testable import MicIngest

/// Stands in for AssemblyAI and Groq. Requests are answered by `handler`; nothing reaches the network.
final class StubProtocol: URLProtocol {
    struct Response {
        var status = 200
        var body = Data()
        static func json(_ string: String, status: Int = 200) -> Response { Response(status: status, body: Data(string.utf8)) }
    }

    nonisolated(unsafe) static var handler: (URLRequest) -> Response = { _ in Response(status: 500) }
    nonisolated(unsafe) static var log: [String] = []
    nonisolated(unsafe) static var headers: [[String: String]] = []
    private static let lock = NSLock()

    static func reset(_ handler: @escaping (URLRequest) -> Response) {
        lock.withLock {
            self.handler = handler
            log = []
            headers = []
        }
    }

    static func count(_ needle: String) -> Int { lock.withLock { log.filter { $0.contains(needle) }.count } }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let response = Self.lock.withLock {
            Self.log.append("\(request.httpMethod ?? "GET") \(request.url?.path ?? "")")
            Self.headers.append(request.allHTTPHeaderFields ?? [:])
            return Self.handler(request)
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

extension URLRequest {
    /// Body of a stubbed request (URLSession hands it to URLProtocol as a stream).
    var bodyData: Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Distinct pipeline stages in the order they were reported (progress arrives from background threads).
final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [ImportStage] = []
    var all: [ImportStage] { lock.withLock { stages } }
    func record(_ stage: ImportStage) { lock.withLock { if stages.last != stage { stages.append(stage) } } }

    /// Every progress update exactly as delivered.
    final class Updates: @unchecked Sendable {
        private let lock = NSLock()
        private var updates: [ImportProgress] = []
        var all: [ImportProgress] { lock.withLock { updates } }
        func append(_ update: ImportProgress) { lock.withLock { updates.append(update) } }
    }
}

final class PipelineTests: XCTestCase {
    var source: URL!
    var destination: URL!
    var database: AppDatabase!
    var defaults: UserDefaults!
    var defaultsName: String!
    var keys: [KeychainStore.Account: String] = [:]

    /// Diarized transcript for the two-chunk fixture session (8 s + 5 s of audio).
    let completedTranscript = """
    {"id": "tr_1", "status": "completed", "language_code": "de", "speech_model_used": "universal-3-5-pro",
     "text": "Hi, ich bin Sam. Hallo Sam, schön dich zu sehen. Wollen wir los?",
     "utterances": [
       {"speaker": "A", "start": 500, "end": 4200, "confidence": 0.95, "text": "Hi, ich bin Sam.", "words": []},
       {"speaker": "B", "start": 4400, "end": 7900, "confidence": 0.93, "text": "Hallo Sam, schön dich zu sehen.", "words": []},
       {"speaker": "A", "start": 8600, "end": 12400, "confidence": 0.9, "text": "Wollen wir los?", "words": []}],
     "words": []}
    """

    let groqFindings = """
    {"speakers": [
      {"speaker": "A", "suggestedName": "Sam", "confidence": "high", "basis": "self_identification",
       "evidence": [{"utteranceId": "u0", "quote": "ich bin Sam", "reason": "The speaker introduces themselves."}]},
      {"speaker": "B", "suggestedName": null, "confidence": "low", "basis": "none", "evidence": []}]}
    """

    override func setUpWithError() throws {
        source = try temporaryDirectory()
        destination = try temporaryDirectory()
        database = try AppDatabase.inMemory()
        defaultsName = "MicIngestTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        keys = [.assemblyAI: "aai-test-key-123", .groq: "gsk-test-key-456"]
        // One session of two chunks (a rollover) plus a separate short take.
        try writeWAV(to: source.appendingPathComponent("TX01_MIC002_20261001_204349_orig.wav"), seconds: 8, sampleRate: 16_000, bitDepth: 24)
        try writeWAV(to: source.appendingPathComponent("TX01_MIC003_20261001_204357_orig.wav"), seconds: 5, sampleRate: 16_000, bitDepth: 24, frequency: 330)
        try writeWAV(to: source.appendingPathComponent("TX01_MIC004_20261001_210000_orig.wav"), seconds: 2, sampleRate: 16_000, bitDepth: 24)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: destination)
        defaults.removePersistentDomain(forName: defaultsName)
        StubProtocol.reset { _ in .init(status: 500) }
    }

    private func pipeline(database: AppDatabase? = nil) -> ImportPipeline {
        let database = database ?? self.database!
        let settings = AppSettings(defaults: defaults)
        let keys = keys
        let assemblyAI = AssemblyAIClient(session: StubProtocol.session) { keys[.assemblyAI] }
        let groq = GroqClient(session: StubProtocol.session) { keys[.groq] }
        let identity = IdentityService(database: database, embedder: SpeakerEmbedder(), groq: groq, settings: settings)
        return ImportPipeline(database: database, assemblyAI: assemblyAI, identity: identity, settings: settings,
                              pollInterval: .milliseconds(10))
    }

    /// Rollover grouping tuned to the short fixture: the 8 s chunk counts as "full length".
    private func sessions() async -> [RecordingSession] {
        let scan = await SourceScanner.scan(source, timeZone: .current)
        return SessionGrouper(rolloverDuration: 8, rolloverSlack: 0.5).group(scan.recordings)
    }

    /// Happy-path service behaviour: upload, queued → processing → completed, Groq finds Sam.
    private func stubServices(pollsBeforeCompletion: Int = 2, groq: StubProtocol.Response? = nil) {
        var polls = 0
        let transcript = completedTranscript, findings = groqFindings
        StubProtocol.reset { request in
            let path = request.url?.path ?? ""
            switch (request.httpMethod ?? "GET", path) {
            case ("POST", "/v2/upload"):
                return .json(#"{"upload_url": "https://cdn.assemblyai.com/upload/fixture"}"#)
            case ("POST", "/v2/transcript"):
                return .json(#"{"id": "tr_1", "status": "queued"}"#)
            case ("GET", "/v2/transcript/tr_1"):
                polls += 1
                return polls > pollsBeforeCompletion ? .json(transcript) : .json(#"{"id": "tr_1", "status": "processing"}"#)
            case ("POST", "/openai/v1/chat/completions"):
                if let groq { return groq }
                let content = String(data: try! JSONEncoder().encode(findings), encoding: .utf8)!
                return .json(#"{"choices": [{"message": {"role": "assistant", "content": \#(content)}}]}"#)
            default:
                return .init(status: 404)
            }
        }
    }

    /// Every file under `folder`, keyed by its path relative to the folder.
    private func snapshot(of folder: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: folder.path) {
            let url = folder.appendingPathComponent(path)
            if (try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { result[path] = try Data(contentsOf: url) }
        }
        return result
    }

    private func modificationDates(of folder: URL) throws -> [String: Date] {
        var result: [String: Date] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            result[name] = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.modificationDate] as? Date
        }
        return result
    }

    // MARK: Tests

    func testFullImportProducesAllArtifactsAndLeavesSourcesUntouched() async throws {
        stubServices()
        let sourceBefore = try snapshot(of: source), datesBefore = try modificationDates(of: source)
        let all = await sessions()
        XCTAssertEqual(all.map(\.recordings.count), [2, 1])

        let pipeline = pipeline()
        let record = try pipeline.register(all[0], destination: destination)
        let stages = StageLog()
        await pipeline.run(sessionID: record.id) { stages.record($0.stage) }
        XCTAssertEqual(stages.all, [.preparing, .merging, .uploading, .transcribing, .analyzingSpeakers, .generatingTranscript, .complete])

        // Sources: byte-identical, same modification dates, nothing added or removed.
        XCTAssertEqual(try snapshot(of: source), sourceBefore)
        XCTAssertEqual(try modificationDates(of: source), datesBefore)

        // The library shows one Markdown transcript; everything else sits in Data, under one basename.
        let base = SessionFiles.basename(for: all[0].start, in: .current)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)), ["\(base).md", "Data"])
        XCTAssertEqual(Set(try snapshot(of: destination).keys),
                       ["\(base).md", "Data/\(base).flac", "Data/\(base).assemblyai.json", "Data/\(base).metadata.json"])

        let finished = try XCTUnwrap(try database.session(id: record.id))
        XCTAssertEqual(finished.stage, .complete)
        XCTAssertEqual(finished.transcriptID, "tr_1")
        XCTAssertNil(finished.failure)

        // Raw response is stored exactly as received.
        let files = SessionFiles(folder: destination, basename: base)
        XCTAssertEqual(try Data(contentsOf: files.rawResponse), Data(completedTranscript.utf8))

        // Metadata describes sources, audio, transcription and speakers.
        let metadata = try SessionMetadata.decode(Data(contentsOf: files.metadata))
        XCTAssertEqual(metadata.sources.map(\.filename), ["TX01_MIC002_20261001_204349_orig.wav", "TX01_MIC003_20261001_204357_orig.wav"])
        XCTAssertEqual(metadata.sources.map(\.offsetSeconds), [0, 8])
        XCTAssertEqual(metadata.audio.frameCount, 13 * 16_000)
        XCTAssertEqual(metadata.audio.bitDepth, 24)
        XCTAssertEqual(metadata.audio.container, .flac)
        XCTAssertEqual(metadata.session.durationSeconds, 13)
        XCTAssertEqual(metadata.transcription?.transcriptID, "tr_1")
        XCTAssertEqual(metadata.transcription?.requestedModels, ["universal-3-5-pro"])
        XCTAssertEqual(metadata.transcription?.modelUsed, "universal-3-5-pro")
        XCTAssertEqual(metadata.identityInference.llm?.status, "ok")
        XCTAssertEqual(metadata.identityInference.llm?.model, "openai/gpt-oss-120b")
        XCTAssertEqual(metadata.identityInference.voice?.dimension, 256)
        XCTAssertEqual(metadata.processing.stage, "complete")
        XCTAssertTrue(metadata.processing.warnings.isEmpty)

        // "Hi, ich bin Sam" → a new person; the other speaker stays Speaker B.
        XCTAssertEqual(metadata.speakers.map(\.displayName), ["Sam", "Speaker B"])
        XCTAssertEqual(metadata.speakers.map(\.state), [.automatic, .unidentified])
        let people = try database.people()
        XCTAssertEqual(people.map(\.displayName), ["Sam"])
        XCTAssertEqual(metadata.speakers[0].personID, people[0].id)
        let evidence = try XCTUnwrap(metadata.speakers[0].evidence.first { $0.source == .selfIdentification })
        XCTAssertEqual(evidence.utteranceIndex, 0)
        XCTAssertEqual(evidence.timestampMs, 500)
        XCTAssertTrue(evidence.applied)

        // Markdown uses wall-clock times derived from the session start.
        let markdown = try String(contentsOf: files.markdown, encoding: .utf8)
        let timeline = metadata.timeline
        XCTAssertTrue(markdown.contains("## \(timeline.clockTime(atMs: 500)) · Sam\n\nHi, ich bin Sam."), markdown)
        XCTAssertTrue(markdown.contains("## \(timeline.clockTime(atMs: 4400)) · Speaker B\n\nHallo Sam, schön dich zu sehen."))
        XCTAssertTrue(markdown.hasPrefix("""
            ---
            date: 2026-10-01
            start: "20:43:49"
            end: "20:44:02"
            duration: 13s
            speakers: [Sam, Speaker B]
            audio: Data/\(base).flac
            ---

            # Recording · 1 October 2026

            ## 20:43:49 · Sam
            """), markdown)

        // One upload, one job.
        XCTAssertEqual(StubProtocol.count("POST /v2/upload"), 1)
        XCTAssertEqual(StubProtocol.count("POST /v2/transcript"), 1)
        XCTAssertEqual(StubProtocol.count("GET /v2/transcript/tr_1"), 3)
    }

    func testProgressThrottlePassesOnOnlyVisibleChanges() {
        let received = StageLog.Updates()
        let throttle = ProgressThrottle { received.append($0) }
        throttle.send(ImportProgress(stage: .preparing))
        throttle.send(ImportProgress(stage: .preparing))
        for step in 0...100_000 { throttle.send(ImportProgress(stage: .merging, fraction: Double(step) / 100_000)) }
        throttle.send(ImportProgress(stage: .uploading, fraction: 0))
        throttle.send(ImportProgress(stage: .transcribing))
        let all = received.all
        XCTAssertEqual(all.count, 1 + 101 + 1 + 1, "one update per stage and per whole percent")
        XCTAssertEqual(all.first, ImportProgress(stage: .preparing))
        XCTAssertEqual(all[1], ImportProgress(stage: .merging, fraction: 0))
        XCTAssertEqual(all[101], ImportProgress(stage: .merging, fraction: 1))
        XCTAssertEqual(all.last, ImportProgress(stage: .transcribing))

        // The time estimate rides along with each percent step instead of causing extra updates.
        let uploads = StageLog.Updates()
        let uploading = ProgressThrottle { uploads.append($0) }
        uploading.send(ImportProgress(stage: .uploading, fraction: 0.251, remaining: 90))
        uploading.send(ImportProgress(stage: .uploading, fraction: 0.255, remaining: 88))
        uploading.send(ImportProgress(stage: .uploading, fraction: 0.262, remaining: 85))
        XCTAssertEqual(uploads.all.map(\.remaining), [90, 85])
        XCTAssertEqual(Format.remaining(4), "a few seconds left")
        XCTAssertEqual(Format.remaining(38), "about 40 s left")
        XCTAssertEqual(Format.remaining(170), "about 3 min left")
    }

    func testLongMergeDoesNotFloodTheUIWithProgressUpdates() async throws {
        // Ten minutes of 48 kHz audio: the merger reports several hundred times while writing and verifying.
        let name = "TX01_MIC050_20261001_120000_orig.wav"
        try writeWAV(to: source.appendingPathComponent(name), seconds: 600, sampleRate: 48_000, bitDepth: 16, repeatingBlock: true)
        stubServices()
        let scan = await SourceScanner.scan(source, timeZone: .current)
        let session = try XCTUnwrap(SessionGrouper().group(scan.recordings).first { $0.recordings[0].filename == name })
        let pipeline = pipeline()
        let record = try pipeline.register(session, destination: destination)
        let received = StageLog.Updates()
        await pipeline.run(sessionID: record.id) { received.append($0) }

        XCTAssertEqual(try database.session(id: record.id)?.stage, .complete)
        let merging = received.all.filter { $0.stage == .merging }
        XCTAssertGreaterThan(merging.count, 50, "progress is still reported")
        XCTAssertLessThanOrEqual(merging.count, 102)
        XCTAssertEqual(merging.compactMap(\.fraction), merging.compactMap(\.fraction).sorted(), "and only moves forward")
        XCTAssertLessThan(received.all.count, 130)
    }

    func testUploadIsASixteenKilohertzRenditionAndTheArchiveStaysLossless() async throws {
        let archive = source.appendingPathComponent("archive.wav")
        try writeWAV(to: archive, seconds: 60, sampleRate: 48_000, bitDepth: 24, repeatingBlock: true)
        let before = try Data(contentsOf: archive)
        let full = AudioFormatInfo(sampleRate: 48_000, channels: 1, bitDepth: 24, isFloat: false)

        let upload = try ImportPipeline.uploadFile(for: archive, format: full)
        defer { try? FileManager.default.removeItem(at: upload.url) }
        XCTAssertTrue(upload.isRendition)
        let rendition = try AVAudioFile(forReading: upload.url)
        XCTAssertEqual(rendition.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(Double(rendition.length) / 16_000, 60, accuracy: 0.1)
        let size = try XCTUnwrap(upload.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThan(size, before.count / 3)
        XCTAssertEqual(try Data(contentsOf: archive), before, "the archive is not touched")

        // Audio that is already 16 kHz / 16-bit goes up as it is.
        let small = AudioFormatInfo(sampleRate: 16_000, channels: 1, bitDepth: 16, isFloat: false)
        let direct = try ImportPipeline.uploadFile(for: archive, format: small)
        XCTAssertEqual(direct.url, archive)
        XCTAssertFalse(direct.isRendition)

        // The metadata says what was sent.
        stubServices()
        let pipeline = pipeline()
        let record = try pipeline.register(await sessions()[0], destination: destination)
        await pipeline.run(sessionID: record.id) { _ in }
        let metadata = try SessionMetadata.decode(Data(contentsOf: SessionFiles(folder: destination, basename: record.basename).metadata))
        XCTAssertEqual(metadata.transcription?.uploadedAudio, "16 kHz 16-bit FLAC rendition of the archive")
        XCTAssertEqual(metadata.audio.bitDepth, 24, "the archive keeps the source bit depth")
    }

    func testNoSecretEndsUpInExportedFilesOrDatabase() async throws {
        stubServices()
        let pipeline = pipeline()
        let record = try pipeline.register(await sessions()[0], destination: destination)
        await pipeline.run(sessionID: record.id) { _ in }

        // The keys were actually used for the requests…
        XCTAssertTrue(StubProtocol.headers.contains { $0["Authorization"] == "aai-test-key-123" })
        XCTAssertTrue(StubProtocol.headers.contains { $0["Authorization"] == "Bearer gsk-test-key-456" })
        // …and appear nowhere on disk.
        for (name, data) in try snapshot(of: destination) where !name.hasSuffix(".flac") {
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("aai-test-key-123") || text.contains("gsk-test-key-456"), name)
        }
        let row = try XCTUnwrap(try database.session(id: record.id))
        let stored = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
        XCTAssertFalse(stored.contains("test-key"))
        XCTAssertTrue(defaults.dictionaryRepresentation().values.allSatisfy { !"\($0)".contains("test-key") })
    }

    func testGroqFailureDoesNotBreakTranscriptionAndCanBeRetriedAlone() async throws {
        stubServices(groq: .json(#"{"error": {"message": "model overloaded"}}"#, status: 400))
        let pipeline = pipeline()
        let record = try pipeline.register(await sessions()[0], destination: destination)
        await pipeline.run(sessionID: record.id) { _ in }

        let store = SessionStore(database: database)
        var session = try XCTUnwrap(try database.session(id: record.id))
        XCTAssertEqual(session.stage, .complete, "identity is an enhancement, not a requirement")
        var metadata = try store.metadata(for: session)
        XCTAssertEqual(metadata.identityInference.llm?.status, "failed")
        XCTAssertEqual(metadata.processing.warnings, [IdentityService.nameInferenceFailedWarning])
        XCTAssertEqual(metadata.speakers.map(\.displayName), ["Speaker A", "Speaker B"])
        let markdown = try String(contentsOf: store.files(for: session).markdown, encoding: .utf8)
        XCTAssertTrue(markdown.contains("· Speaker A\n\nHi, ich bin Sam."))

        // Retry only the speaker analysis: no new upload, no new transcription job.
        stubServices()
        try await pipeline.reanalyze(sessionID: record.id)
        XCTAssertEqual(StubProtocol.count("/v2/"), 0)
        XCTAssertEqual(StubProtocol.count("/chat/completions"), 1)
        session = try XCTUnwrap(try database.session(id: record.id))
        metadata = try store.metadata(for: session)
        XCTAssertEqual(metadata.speakers.map(\.displayName), ["Sam", "Speaker B"])
        XCTAssertTrue(metadata.processing.warnings.isEmpty)
        XCTAssertTrue(try String(contentsOf: store.files(for: session).markdown, encoding: .utf8).contains("· Sam\n\nHi, ich bin Sam."))
    }

    func testMissingGroqKeySkipsNameInferenceQuietly() async throws {
        stubServices()
        keys[.groq] = nil
        let pipeline = pipeline()
        let record = try pipeline.register(await sessions()[0], destination: destination)
        await pipeline.run(sessionID: record.id) { _ in }
        let session = try XCTUnwrap(try database.session(id: record.id))
        XCTAssertEqual(session.stage, .complete)
        let metadata = try SessionStore(database: database).metadata(for: session)
        XCTAssertEqual(metadata.identityInference.llm?.status, "skipped")
        XCTAssertEqual(StubProtocol.count("/chat/completions"), 0)
        XCTAssertEqual(metadata.speakers.map(\.displayName), ["Speaker A", "Speaker B"])
    }

    func testMissingAssemblyAIKeyFailsWithActionableMessageAfterMerging() async throws {
        stubServices()
        keys[.assemblyAI] = nil
        let pipeline = pipeline()
        let record = try pipeline.register(await sessions()[0], destination: destination)
        await pipeline.run(sessionID: record.id) { _ in }
        let session = try XCTUnwrap(try database.session(id: record.id))
        XCTAssertEqual(session.stage, .failed)
        XCTAssertEqual(session.lastActiveStage, .uploading)
        XCTAssertEqual(session.failure, "AssemblyAI API key is missing. Add it in Settings.")
        XCTAssertNotNil(session.audioFilename, "the merged audio is kept")
        XCTAssertEqual(StubProtocol.log, [])
    }

    func testResumeAfterTranscriptionFailureDoesNotMergeOrUploadAgain() async throws {
        // First run: upload and job creation work, then polling keeps failing with a server error.
        var failPolling = true
        let transcript = completedTranscript, findings = groqFindings
        StubProtocol.reset { request in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("POST", "/v2/upload"): return .json(#"{"upload_url": "https://cdn.assemblyai.com/upload/fixture"}"#)
            case ("POST", "/v2/transcript"): return .json(#"{"id": "tr_1", "status": "queued"}"#)
            case ("GET", "/v2/transcript/tr_1"): return failPolling ? .init(status: 401) : .json(transcript)
            default:
                let content = String(data: try! JSONEncoder().encode(findings), encoding: .utf8)!
                return .json(#"{"choices": [{"message": {"content": \#(content)}}]}"#)
            }
        }
        let pipeline = pipeline()
        let record = try pipeline.register(await sessions()[0], destination: destination)
        await pipeline.run(sessionID: record.id) { _ in }
        var session = try XCTUnwrap(try database.session(id: record.id))
        XCTAssertEqual(session.stage, .failed)
        XCTAssertEqual(session.lastActiveStage, .transcribing)
        XCTAssertEqual(session.transcriptID, "tr_1", "the transcript ID is persisted as soon as it exists")
        let audio = destination.appendingPathComponent("Data").appendingPathComponent(try XCTUnwrap(session.audioFilename))
        let audioDate = try FileManager.default.attributesOfItem(atPath: audio.path)[.modificationDate] as? Date

        // Second run, e.g. after an app restart: continues with polling only.
        failPolling = false
        StubProtocol.log = []
        let stages = StageLog()
        await self.pipeline().run(sessionID: record.id) { stages.record($0.stage) }
        session = try XCTUnwrap(try database.session(id: record.id))
        XCTAssertEqual(session.stage, .complete)
        XCTAssertEqual(StubProtocol.count("POST"), 1, "only the Groq call; no second upload or job")
        XCTAssertEqual(StubProtocol.count("/v2/upload"), 0)
        XCTAssertFalse(stages.all.contains(.merging))
        XCTAssertFalse(stages.all.contains(.uploading))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: audio.path)[.modificationDate] as? Date, audioDate)
    }

    func testFailedTranscriptionJobIsResubmittedOnRetry() async throws {
        var jobs = 0
        let transcript = completedTranscript
        StubProtocol.reset { request in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("POST", "/v2/upload"): return .json(#"{"upload_url": "https://cdn.assemblyai.com/upload/fixture"}"#)
            case ("POST", "/v2/transcript"):
                jobs += 1
                return .json(#"{"id": "tr_\#(jobs)", "status": "queued"}"#)
            case ("GET", "/v2/transcript/tr_1"): return .json(#"{"id": "tr_1", "status": "error", "error": "Download error"}"#)
            case ("GET", "/v2/transcript/tr_2"): return .json(transcript.replacingOccurrences(of: "tr_1", with: "tr_2"))
            default: return .json(#"{"choices": [{"message": {"content": "{\"speakers\": []}"}}]}"#)
            }
        }
        let pipeline = pipeline()
        let record = try pipeline.register(await sessions()[0], destination: destination)
        await pipeline.run(sessionID: record.id) { _ in }
        var session = try XCTUnwrap(try database.session(id: record.id))
        XCTAssertEqual(session.stage, .failed)
        XCTAssertEqual(session.failure, "Transcription failed (Download error). Retry.")
        XCTAssertNil(session.transcriptID)

        await pipeline.run(sessionID: record.id) { _ in }
        session = try XCTUnwrap(try database.session(id: record.id))
        XCTAssertEqual(session.stage, .complete)
        XCTAssertEqual(session.transcriptID, "tr_2")
        XCTAssertEqual(StubProtocol.count("POST /v2/upload"), 2)
    }

    func testImportingTheSameSessionTwiceIsRecognised() async throws {
        stubServices()
        let all = await sessions()
        let pipeline = pipeline()
        let first = try pipeline.register(all[0], destination: destination)
        await pipeline.run(sessionID: first.id) { _ in }
        let filesBefore = try snapshot(of: destination)

        // Same session again, even into another folder: the existing import is returned.
        let other = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: other) }
        let second = try pipeline.register(all[0], destination: other)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.stage, .complete)
        XCTAssertEqual(try database.sessions().count, 1)
        XCTAssertEqual(Set(try snapshot(of: destination).keys), Set(filesBefore.keys))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)

        // Its chunks are known as imported for later scans.
        let imported = try database.importedSources()
        XCTAssertEqual(Set(imported.keys), Set(all[0].recordings.map(\.fingerprint)))
        XCTAssertNil(imported[all[1].recordings[0].fingerprint])
    }

    func testExistingExportIsAdoptedWhenTheDatabaseIsGone() async throws {
        stubServices()
        let all = await sessions()
        let first = try pipeline().register(all[0], destination: destination)
        await pipeline().run(sessionID: first.id) { _ in }
        let filesBefore = try snapshot(of: destination)

        // A fresh database (app data deleted), same destination folder.
        let fresh = try AppDatabase.inMemory()
        StubProtocol.log = []
        let adopted = try pipeline(database: fresh).register(all[0], destination: destination)
        XCTAssertEqual(adopted.id, first.id)
        XCTAssertEqual(adopted.basename, first.basename)
        XCTAssertEqual(adopted.transcriptID, "tr_1")
        await pipeline(database: fresh).run(sessionID: adopted.id) { _ in }
        XCTAssertEqual(try fresh.session(id: adopted.id)?.stage, .complete)
        XCTAssertEqual(StubProtocol.count("/v2/"), 0, "nothing is uploaded or transcribed again")
        XCTAssertEqual(try fresh.people().map(\.displayName), ["Sam"], "people named in the export are known again")
        XCTAssertEqual(Set(try snapshot(of: destination).keys), Set(filesBefore.keys), "no duplicate files")
    }

    func testFilenameCollisionWithUnrelatedFilesGetsASuffix() async throws {
        let all = await sessions()
        let base = SessionFiles.basename(for: all[0].start, in: .current)
        let unrelated = destination.appendingPathComponent("\(base).md")
        try Data("my own notes".utf8).write(to: unrelated)

        stubServices()
        let pipeline = pipeline()
        let record = try pipeline.register(all[0], destination: destination)
        XCTAssertEqual(record.basename, "\(base)-2")
        await pipeline.run(sessionID: record.id) { _ in }
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "my own notes", "unrelated file is not overwritten")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Data/\(base)-2.flac").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("\(base)-2.md").path))
    }

    func testPlacementRules() throws {
        let start = date("2026-10-01 20:43:49")
        XCTAssertEqual(SessionFiles.basename(for: start, in: berlin), "2026-10-01_20-43-49")
        guard case .new(let files) = SessionFiles.place(start: start, timeZone: berlin, fingerprint: "abcd1234ffff", in: destination) else {
            return XCTFail("expected a new placement")
        }
        XCTAssertEqual(files.basename, "2026-10-01_20-43-49")

        // Same session already exported there → recognised; a different one → new name.
        try FileManager.default.createDirectory(at: files.data, withIntermediateDirectories: true)
        try sampleMetadata().encoded().write(to: files.metadata)
        XCTAssertEqual(SessionFiles.place(start: start, timeZone: berlin, fingerprint: "abcd1234ffff", in: destination), .existing(files))
        XCTAssertEqual(SessionFiles.place(start: start, timeZone: berlin, fingerprint: "another", in: destination),
                       .new(SessionFiles(folder: destination, basename: "2026-10-01_20-43-49-2")))
    }

    func testManualRenameUpdatesMetadataMarkdownAndVoiceProfileWithoutRetranscribing() async throws {
        stubServices()
        let pipeline = pipeline()
        let record = try pipeline.register(await sessions()[0], destination: destination)
        await pipeline.run(sessionID: record.id) { _ in }
        let rawBefore = try Data(contentsOf: SessionFiles(folder: destination, basename: record.basename).rawResponse)
        StubProtocol.log = []

        let store = SessionStore(database: database)
        var session = try XCTUnwrap(try database.session(id: record.id))
        let transcript = try store.transcript(for: session)
        let identity = pipeline.identity
        let robert = try database.createPerson(named: "Robert")

        // Speaker B → Robert.
        var metadata = await identity.apply(.person(robert.id), to: "B", transcript: transcript,
                                            metadata: try store.metadata(for: session), audio: store.audioURL(for: session))
        try store.save(metadata, for: &session)
        try store.writeMarkdown(transcript: transcript, metadata: metadata, for: session)

        let onDisk = try SessionMetadata.decode(Data(contentsOf: store.files(for: session).metadata))
        let entry = try XCTUnwrap(onDisk.speakers.first { $0.label == "B" })
        XCTAssertEqual(entry.displayName, "Robert")
        XCTAssertEqual(entry.personID, robert.id)
        XCTAssertEqual(entry.state, .manual)
        XCTAssertEqual(entry.evidence.first, IdentityEvidence(source: .manual, applied: true, personID: robert.id))
        XCTAssertTrue(try String(contentsOf: store.files(for: session).markdown, encoding: .utf8).contains("· Robert\n\nHallo Sam, schön dich zu sehen."))
        XCTAssertEqual(try Data(contentsOf: store.files(for: session).rawResponse), rawBefore, "the raw response is never modified")
        XCTAssertEqual(StubProtocol.log, [], "no network involved")

        // Keep unidentified, then remove again: display name falls back, state is tracked.
        metadata = await identity.apply(.unidentified, to: "B", transcript: transcript, metadata: metadata, audio: nil)
        XCTAssertEqual(metadata.speakers.first { $0.label == "B" }?.state, .manualUnidentified)
        XCTAssertEqual(metadata.speakers.first { $0.label == "B" }?.displayName, "Speaker B")
        metadata = await identity.apply(nil, to: "B", transcript: transcript, metadata: metadata, audio: nil)
        XCTAssertEqual(metadata.speakers.first { $0.label == "B" }?.state, .unidentified)

        // Renaming a person reaches every session that references them.
        let sam = try XCTUnwrap(try database.people().first { $0.displayName == "Sam" })
        try database.rename(personID: sam.id, to: "Sam K.")
        let refreshed = try XCTUnwrap(identity.refreshed(metadata, people: try database.people()))
        XCTAssertEqual(refreshed.speakers.first { $0.label == "A" }?.displayName, "Sam K.")
        // Deleting them returns the speaker to unidentified.
        try database.deletePerson(id: sam.id)
        let afterDelete = try XCTUnwrap(identity.refreshed(refreshed, people: try database.people()))
        XCTAssertEqual(afterDelete.speakers.first { $0.label == "A" }?.displayName, "Speaker A")
        XCTAssertNil(afterDelete.speakers.first { $0.label == "A" }?.personID)
    }

    func testRecorderClockInAnotherZoneIsConvertedToLocalTime() async throws {
        stubServices()
        // The recorder runs on UTC+8 (factory setting); the user lives in Berlin.
        let china = TimeZone(secondsFromGMT: 8 * 3600)!
        AppSettings(defaults: defaults).recorderTimeZone = china
        XCTAssertEqual(AppSettings(defaults: defaults).recorderTimeZone?.secondsFromGMT(), 28_800)
        let scan = await SourceScanner.scan(source, timeZone: china)
        let session = SessionGrouper(rolloverDuration: 8, rolloverSlack: 0.5).group(scan.recordings)[0]
        XCTAssertEqual(session.start, date("2026-10-01 14:43:49"), "20:43:49 on the recorder is 14:43:49 in Berlin")
        XCTAssertEqual(session.recordings.count, 2, "grouping does not depend on the zone")

        let pipeline = pipeline()
        let record = try pipeline.register(session, destination: destination, timeZone: berlin)
        XCTAssertEqual(record.basename, "2026-10-01_14-43-49")
        await pipeline.run(sessionID: record.id) { _ in }

        let files = SessionFiles(folder: destination, basename: record.basename)
        let metadata = try SessionMetadata.decode(Data(contentsOf: files.metadata))
        XCTAssertEqual(metadata.session.timeZone, "Europe/Berlin")
        XCTAssertEqual(metadata.session.recorderTimeZone, china.identifier)
        XCTAssertEqual(metadata.sources.map(\.start), [date("2026-10-01 14:43:49"), date("2026-10-01 14:43:57")])
        let markdown = try String(contentsOf: files.markdown, encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix("---\ndate: 2026-10-01\nstart: \"14:43:49\"\nend: \"14:44:02\"\n"), markdown)
        XCTAssertTrue(markdown.contains("\n# Recording · 1 October 2026\n\n## 14:43:49 · Sam\n"), markdown)

        // The same files scanned with a different clock setting are still recognised as imported.
        let rescanned = await SourceScanner.scan(source, timeZone: berlin)
        let again = SessionGrouper(rolloverDuration: 8, rolloverSlack: 0.5).group(rescanned.recordings)[0]
        XCTAssertEqual(again.fingerprint, session.fingerprint)
        XCTAssertEqual(try pipeline.register(again, destination: destination, timeZone: berlin).id, record.id)
    }

    @MainActor
    func testRenamingAndDeletingAPersonRewritesTranscripts() async throws {
        stubServices()
        let pipeline = pipeline()
        let record = try pipeline.register(await sessions()[0], destination: destination)
        await pipeline.run(sessionID: record.id) { _ in }
        let files = SessionFiles(folder: destination, basename: record.basename)
        let rawBefore = try Data(contentsOf: files.rawResponse)
        StubProtocol.log = []

        let people = PeopleModel(database: database, identity: pipeline.identity, settings: AppSettings(defaults: defaults))
        let sam = try XCTUnwrap(people.people.first { $0.displayName == "Sam" })
        people.rename(sam, to: "Jules")
        XCTAssertTrue(try String(contentsOf: files.markdown, encoding: .utf8).contains("· Jules\n\nHi, ich bin Sam."))
        XCTAssertEqual(try SessionMetadata.decode(Data(contentsOf: files.metadata)).speakers[0].displayName, "Jules")

        people.delete(try XCTUnwrap(people.people.first))
        let metadata = try SessionMetadata.decode(Data(contentsOf: files.metadata))
        XCTAssertEqual(metadata.speakers[0].displayName, "Speaker A")
        XCTAssertEqual(metadata.speakers[0].state, .unidentified)
        XCTAssertNil(metadata.speakers[0].personID)
        XCTAssertTrue(try String(contentsOf: files.markdown, encoding: .utf8).contains("· Speaker A\n\nHi, ich bin Sam."))
        XCTAssertTrue(people.people.isEmpty)
        XCTAssertEqual(try Data(contentsOf: files.rawResponse), rawBefore)
        XCTAssertEqual(StubProtocol.log, [], "names change without any network call")
    }

    func testLibraryFolderRestoresSessionsPeopleAndVoiceProfilesIntoAnEmptyDatabase() async throws {
        stubServices()
        let all = await sessions()
        let pipeline = pipeline()
        let record = try pipeline.register(all[0], destination: destination)
        await pipeline.run(sessionID: record.id) { _ in }
        // Give Sam a voice sample and name speaker B by hand, then write the people file as the app does.
        let sam = try XCTUnwrap(try database.people().first)
        let sample = VoiceSample(id: "sample-1", personID: sam.id, modelVersion: SpeakerEmbedder.modelVersion,
                                 embedding: VoiceSample.data([0.6, 0.8, 0, 0]), provenance: .explicitSelfIdentification,
                                 sessionID: record.id, speakerLabel: "A", speechSeconds: 12, createdAt: date("2026-10-02 09:00:00"))
        try database.replaceVoiceSample(sessionID: record.id, speakerLabel: "A", with: sample, limitPerPerson: 24)
        let library = LibraryFolder(root: destination)
        try library.writePeople(from: database)
        let peopleJSON = try String(contentsOf: library.peopleFile, encoding: .utf8)
        XCTAssertTrue(peopleJSON.contains("\"displayName\" : \"Sam\""))
        let filesBefore = try snapshot(of: destination)
        StubProtocol.log = []

        // A new Mac: empty database, same library folder.
        let fresh = try AppDatabase.inMemory()
        XCTAssertEqual(try library.mergePeople(into: fresh), 2, "one person and one voice sample")
        XCTAssertEqual(try library.restoreSessions(into: fresh), 1)
        XCTAssertEqual(try library.restoreSessions(into: fresh), 0, "restoring twice adds nothing")
        XCTAssertEqual(try library.mergePeople(into: fresh), 0)

        let restored = try XCTUnwrap(try fresh.sessions().first)
        XCTAssertEqual(restored.id, record.id)
        XCTAssertEqual(restored.stage, .complete)
        XCTAssertEqual(restored.basename, record.basename)
        XCTAssertEqual(restored.transcriptID, "tr_1")
        XCTAssertEqual(try fresh.people().map(\.displayName), ["Sam"])
        XCTAssertEqual(try fresh.voiceSamples(modelVersion: SpeakerEmbedder.modelVersion).map(\.vector), [[0.6, 0.8, 0, 0]])
        let store = SessionStore(database: fresh)
        XCTAssertEqual(try store.metadata(for: restored).speakers.map(\.displayName), ["Sam", "Speaker B"])
        XCTAssertEqual(try store.transcript(for: restored).utterances.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(store.audioURL(for: restored)).path))
        // The recorder's chunks are recognised as imported again.
        XCTAssertEqual(Set(try fresh.importedSources().keys), Set(all[0].recordings.map(\.fingerprint)))
        // Restoring reads; it changes nothing in the folder and needs no network.
        XCTAssertEqual(try snapshot(of: destination), filesBefore)
        XCTAssertEqual(StubProtocol.log, [])

        // Removing voice data locally is written back, not resurrected from the file.
        try fresh.deleteVoiceSamples(personID: sam.id)
        try library.writePeople(from: fresh)
        XCTAssertFalse(try String(contentsOf: library.peopleFile, encoding: .utf8).contains("sample-1"))
    }

    func testEachLibraryKeepsItsOwnPeopleAndVoiceProfiles() async throws {
        let personal = destination!, work = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        // Alex is known, with a voice profile, in the personal library only.
        let alex = try database.createPerson(named: "Alex", library: personal.path)
        try database.replaceVoiceSample(sessionID: "earlier", speakerLabel: "A", with: VoiceSample(
            id: "alex-1", personID: alex.id, modelVersion: SpeakerEmbedder.modelVersion, embedding: VoiceSample.data([1, 0, 0, 0]),
            provenance: .manualConfirmation, sessionID: "earlier", speakerLabel: "A", speechSeconds: 20, createdAt: Date()), limitPerPerson: 24)

        // A recording imported into the work library, where someone introduces themselves as Sam.
        stubServices()
        let pipeline = pipeline()
        let record = try pipeline.register(await sessions()[0], destination: work)
        await pipeline.run(sessionID: record.id) { _ in }

        XCTAssertEqual(try database.people(in: work.path).map(\.displayName), ["Sam"], "created in the library the session went to")
        XCTAssertEqual(try database.people(in: personal.path).map(\.displayName), ["Alex"])
        XCTAssertEqual(try database.voiceSamples(modelVersion: SpeakerEmbedder.modelVersion, library: work.path).count, 0)
        XCTAssertEqual(try database.voiceSamples(modelVersion: SpeakerEmbedder.modelVersion, library: personal.path).map(\.id), ["alex-1"])

        // Each library's people file holds only its own people: nothing personal ends up in the shared one.
        try LibraryFolder(root: work).writePeople(from: database)
        try LibraryFolder(root: personal).writePeople(from: database)
        let workPeople = try String(contentsOf: LibraryFolder(root: work).peopleFile, encoding: .utf8)
        XCTAssertTrue(workPeople.contains("Sam"))
        XCTAssertFalse(workPeople.contains("Alex") || workPeople.contains("alex-1"))
        XCTAssertTrue(try String(contentsOf: LibraryFolder(root: personal).peopleFile, encoding: .utf8).contains("alex-1"))

        // Removing a library from the app forgets its sessions and people, and leaves its folder alone.
        let workFiles = try snapshot(of: work)
        try database.removeLibrary(path: work.path)
        XCTAssertTrue(try database.sessions().isEmpty)
        XCTAssertEqual(try database.people().map(\.displayName), ["Alex"])
        XCTAssertEqual(try snapshot(of: work), workFiles)
        // Adding it again brings everything back from the folder.
        XCTAssertEqual(try LibraryFolder(root: work).mergePeople(into: database), 1)
        XCTAssertEqual(try LibraryFolder(root: work).restoreSessions(into: database), 1)
        XCTAssertEqual(try database.people(in: work.path).map(\.displayName), ["Sam"])
    }

    func testTrashingASessionRemovesItsFilesAndRecord() async throws {
        stubServices()
        let pipeline = pipeline()
        let record = try pipeline.register(await sessions()[0], destination: destination)
        await pipeline.run(sessionID: record.id) { _ in }
        let session = try XCTUnwrap(try database.session(id: record.id))
        var discarded: [String] = []
        try SessionStore(database: database).trash(session) { url in
            discarded.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
        XCTAssertEqual(discarded.count, 4, "transcript, raw response, metadata and audio")
        XCTAssertTrue(try snapshot(of: destination).isEmpty)
        XCTAssertNil(try database.session(id: record.id))
        XCTAssertEqual(try LibraryFolder(root: destination).restoreSessions(into: database), 0, "it does not come back on the next reload")
    }

    func testUnfinishedSessionInLibraryIsRestoredAsResumable() async throws {
        // Transcription never completes in the first run, so only audio and metadata reach the library.
        keys[.assemblyAI] = nil
        stubServices()
        let all = await sessions()
        let record = try pipeline().register(all[0], destination: destination)
        await pipeline().run(sessionID: record.id) { _ in }

        let fresh = try AppDatabase.inMemory()
        XCTAssertEqual(try LibraryFolder(root: destination).restoreSessions(into: fresh), 1)
        let restored = try XCTUnwrap(try fresh.session(id: record.id))
        XCTAssertEqual(restored.stage, .failed)
        XCTAssertNotNil(restored.audioFilename)

        keys[.assemblyAI] = "aai-test-key-123"
        await pipeline(database: fresh).run(sessionID: record.id) { _ in }
        XCTAssertEqual(try fresh.session(id: record.id)?.stage, .complete, "resumes from the merged audio without the recorder")
        XCTAssertEqual(StubProtocol.count("POST /v2/upload"), 1)
    }

    func testFilesFromTheOldLooseLayoutAreMovedIntoTheLibraryLayout() async throws {
        stubServices()
        let pipeline = pipeline()
        var record = try pipeline.register(await sessions()[0], destination: destination)
        await pipeline.run(sessionID: record.id) { _ in }
        record = try XCTUnwrap(try database.session(id: record.id))
        // Recreate what the first builds wrote: all four files side by side, Markdown without a header.
        let base = record.basename, data = destination.appendingPathComponent("Data")
        for name in ["\(base).flac", "\(base).assemblyai.json", "\(base).metadata.json"] {
            try FileManager.default.moveItem(at: data.appendingPathComponent(name), to: destination.appendingPathComponent(name))
        }
        try FileManager.default.removeItem(at: data)
        try Data("# Recording · 1 October 2026\n".utf8).write(to: destination.appendingPathComponent("\(base).md"))
        let audioBefore = try Data(contentsOf: destination.appendingPathComponent("\(base).flac"))

        let store = SessionStore(database: database)
        store.migrateLegacyLayout(record)
        store.migrateLegacyLayout(record)   // idempotent

        XCTAssertEqual(Set(try snapshot(of: destination).keys),
                       ["\(base).md", "Data/\(base).flac", "Data/\(base).assemblyai.json", "Data/\(base).metadata.json"])
        XCTAssertEqual(try Data(contentsOf: data.appendingPathComponent("\(base).flac")), audioBefore)
        XCTAssertTrue(try String(contentsOf: destination.appendingPathComponent("\(base).md"), encoding: .utf8).hasPrefix("---\ndate: 2026-10-01\n"))
        XCTAssertEqual(try store.metadata(for: record).speakers.map(\.displayName), ["Sam", "Speaker B"])
    }

    func testTrimmedImportKeepsOnlyThatPartWithCorrectClockTimes() async throws {
        stubServices()
        let all = await sessions()   // MIC002 (8 s, 20:43:49) + MIC003 (5 s, 20:43:57)
        // Keep from 3 s into MIC002 to 2 s into MIC003.
        let trim = Trim(start: 3, end: 10)
        let pipeline = pipeline()
        let record = try pipeline.register(all[0], destination: destination, trim: trim)
        XCTAssertEqual(record.start, date("2026-10-01 20:43:52", in: .current))
        XCTAssertEqual(record.basename, "2026-10-01_20-43-52")
        await pipeline.run(sessionID: record.id) { _ in }
        XCTAssertEqual(try database.session(id: record.id)?.stage, .complete)

        let files = SessionFiles(folder: destination, basename: record.basename)
        let metadata = try SessionMetadata.decode(Data(contentsOf: files.metadata))
        XCTAssertEqual(metadata.audio.frameCount, 7 * 16_000)
        XCTAssertEqual(metadata.session.durationSeconds, 7)
        XCTAssertEqual(metadata.session.start, date("2026-10-01 20:43:52", in: .current))
        XCTAssertEqual(metadata.session.end, date("2026-10-01 20:43:59", in: .current))
        XCTAssertEqual(metadata.session.trim, .init(startSeconds: 3, endSeconds: 10, untrimmedDurationSeconds: 13))
        XCTAssertEqual(metadata.sources.map(\.offsetSeconds), [0, 5])
        XCTAssertEqual(metadata.sources.map(\.skippedSeconds), [3, nil])
        // Transcript positions map to the clock times of the part that was kept.
        XCTAssertEqual(metadata.timeline.clockTime(atMs: 0), "20:43:52")
        XCTAssertEqual(metadata.timeline.clockTime(atMs: 6_000), "20:43:58")
        let markdown = try String(contentsOf: files.markdown, encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix("---\ndate: 2026-10-01\nstart: \"20:43:52\"\nend: \"20:43:59\"\nduration: 7s\n"), markdown)
        XCTAssertTrue(markdown.contains("## 20:43:52 · Sam"), "first utterance at 0.5 s → 20:43:52")
        // Still the same recording for duplicate detection.
        XCTAssertEqual(try pipeline.register(all[0], destination: destination).id, record.id)
    }

    func testStateSurvivesReopeningTheDatabase() async throws {
        let path = destination.appendingPathComponent("state.sqlite").path
        var onDisk: AppDatabase? = try AppDatabase(DatabaseQueue(path: path))
        stubServices()
        let record = try pipeline(database: onDisk).register(await sessions()[0], destination: destination)
        await pipeline(database: onDisk).run(sessionID: record.id) { _ in }
        try onDisk?.setBoundaryOverride(.split, for: "some-chunk")
        onDisk = nil

        let reopened = try AppDatabase(DatabaseQueue(path: path))
        let session = try XCTUnwrap(try reopened.session(id: record.id))
        XCTAssertEqual(session.stage, .complete)
        XCTAssertEqual(session.transcriptID, "tr_1")
        XCTAssertEqual(try reopened.people().map(\.displayName), ["Sam"])
        XCTAssertEqual(try reopened.boundaryOverrides(), ["some-chunk": .split])
        XCTAssertEqual(try SessionStore(database: reopened).metadata(for: session).speakers.first?.displayName, "Sam")
        XCTAssertFalse(try reopened.importedSources().isEmpty)
    }
}
