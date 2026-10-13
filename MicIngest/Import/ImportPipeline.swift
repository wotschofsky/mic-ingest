import Foundation

struct ImportProgress: Equatable {
    var stage: ImportStage
    /// Only set where a real fraction is known (merging, uploading). Never estimated.
    /// Transcription has none: AssemblyAI only reports queued / processing / completed / error.
    /// Discussed but not built: telling queued from processing, elapsed time, and an estimate learned
    /// from past jobs' submitted/completed times (already stored in each recording's metadata).
    var fraction: Double?
    /// Uploads only: time left at the transfer rate measured so far.
    var remaining: TimeInterval?
}

/// Passes on a progress value only when it would look different on screen: a new stage or a new
/// whole percent. Merging and uploading report hundreds of times per second; handing each of those
/// to the UI keeps the main thread too busy to do anything else.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: ImportProgress?
    private let forward: @Sendable (ImportProgress) -> Void

    init(_ forward: @escaping @Sendable (ImportProgress) -> Void) { self.forward = forward }

    func send(_ progress: ImportProgress) {
        var shown = progress
        shown.fraction = progress.fraction.map { ($0 * 100).rounded(.down) / 100 }
        let changed = lock.withLock {
            defer { last = shown }
            return last?.stage != shown.stage || last?.fraction != shown.fraction
        }
        if changed { forward(shown) }
    }
}

enum ImportError: LocalizedError {
    case sourceUnavailable
    case destinationUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            "The source recordings are not available. Connect the recorder (or reselect the source folder) and retry."
        case .destinationUnavailable(let path):
            "The destination folder \(path) is not available."
        }
    }
}

/// Takes one session from source chunks to merged audio, transcript, speaker identities and Markdown.
///
/// Every stage first checks what already exists (in the database and the destination folder) and
/// skips work that is done, so `run` is safe to call again after a failure or an app restart:
/// nothing is merged, uploaded or transcribed twice.
struct ImportPipeline {
    var database: AppDatabase
    var assemblyAI: AssemblyAIClient
    var identity: IdentityService
    var settings: AppSettings
    var pollInterval = AppConfig.AssemblyAI.pollInterval

    private var store: SessionStore { SessionStore(database: database) }

    /// Stable for a given set of source chunks: transmitter, start time and a slice of the fingerprint.
    static func sessionID(for session: RecordingSession, timeZone: TimeZone, trim: Trim? = nil) -> String {
        "\(session.transmitter)-\(SessionFiles.basename(for: session.start(trimmedBy: trim), in: timeZone))-\(session.fingerprint.prefix(8))"
    }

    // MARK: Registration and duplicate handling

    /// Registers a session for import into `destination`, or returns the existing record if this
    /// exact session was imported before (also when only the exported files remain).
    /// `timeZone` is the zone clock times are written in (file names, Markdown, metadata).
    /// `trim` limits the import to that part of the session.
    func register(_ session: RecordingSession, destination: URL, timeZone: TimeZone = .current,
                  trim: Trim? = nil) throws -> ImportedSession {
        // Matched by fingerprint across all libraries: a recording lives in exactly one library. The same
        // session cannot go into a second library, nor be re-imported with a different trim, until the
        // first import is moved to the Trash. (Keeps session IDs, voice samples and duplicate detection simple.)
        if let existing = try database.sessions().first(where: { $0.fingerprint == session.fingerprint }) {
            return existing
        }
        guard (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw ImportError.destinationUnavailable(destination.path)
        }
        // File name, session ID and clock times describe what was actually kept, i.e. the trimmed start.
        let start = session.start(trimmedBy: trim), end = session.end(trimmedBy: trim)
        let placement = SessionFiles.place(start: start, timeZone: timeZone, fingerprint: session.fingerprint, in: destination)
        let now = Date()
        var record = ImportedSession(
            id: Self.sessionID(for: session, timeZone: timeZone, trim: trim), fingerprint: session.fingerprint, transmitter: session.transmitter,
            start: start, end: end, timeZone: timeZone.identifier,
            recorderTimeZone: (settings.recorderTimeZone ?? timeZone).identifier, basename: "",
            destinationPath: destination.path, destinationBookmark: FolderAccess.bookmark(for: destination),
            audioFilename: nil, stage: .preparing, lastActiveStage: nil, failure: nil, transcriptID: nil,
            transcriptSubmittedAt: nil, sources: session.recordings.map { SourceReference(path: $0.url.path, start: $0.start) },
            trimStart: trim?.start, trimEnd: trim?.end, metadataJSON: nil,
            createdAt: now, updatedAt: now)

        switch placement {
        case .new(let files):
            record.basename = files.basename
        case .existing(let files):
            // The library already holds this session (e.g. the app database was reset): adopt it,
            // then let `run` check it over and finish whatever is missing.
            record.basename = files.basename
            if let data = try? Data(contentsOf: files.metadata), let metadata = try? SessionMetadata.decode(data) {
                let sources = record.sources
                record = LibraryFolder.record(adopting: metadata, encoded: data, files: files)
                record.sources = sources
                record.stage = .preparing
                record.failure = nil
                try database.addMissing(people: metadata.speakers.compactMap { speaker in
                    speaker.personID.map { Person(id: $0, displayName: speaker.displayName, createdAt: now, library: destination.path) }
                }, samples: [])
            }
            Log.pipeline.info("Adopting existing export \(files.basename, privacy: .public)")
        }
        try database.insert(record, sourceFingerprints: session.recordings.map(\.fingerprint))
        return record
    }

    // MARK: Running

    /// Runs (or resumes) the import. Outcome is recorded on the session; nothing is thrown.
    func run(sessionID: String, progress report: @escaping @Sendable (ImportProgress) -> Void) async {
        guard var session = try? database.session(id: sessionID) else { return }
        let throttle = ProgressThrottle(report)
        let progress: @Sendable (ImportProgress) -> Void = { throttle.send($0) }
        let folder = store.files(for: session).folder
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        var active = ImportStage.preparing
        func enter(_ stage: ImportStage) throws {
            try Task.checkCancellation()
            active = stage
            session.stage = stage
            session.failure = nil
            try database.save(session)
            progress(ImportProgress(stage: stage))
            Log.pipeline.info("\(session.basename, privacy: .public): \(stage.rawValue, privacy: .public)")
        }

        do {
            try enter(.preparing)
            guard FileManager.default.fileExists(atPath: folder.path) else {
                throw ImportError.destinationUnavailable(folder.path)
            }
            let files = store.files(for: session)
            try FileManager.default.createDirectory(at: files.data, withIntermediateDirectories: true)
            let started = Date()

            // Merge → lossless archive.
            var metadata: SessionMetadata
            if let audio = session.audioFilename, FileManager.default.fileExists(atPath: files.audio(named: audio).path),
               let existing = try? store.metadata(for: session) {
                metadata = existing
            } else {
                try enter(.merging)
                metadata = try await merge(&session, files: files, progress: progress)
            }
            let audioURL = files.audio(named: metadata.audio.filename)

            // Upload + transcribe. The transcript ID is persisted the moment it exists.
            if !FileManager.default.fileExists(atPath: files.rawResponse.path) {
                if session.transcriptID == nil {
                    try enter(.uploading)
                    let audio = metadata.audio
                    let (request, uploaded) = try await upload(
                        audioURL, format: AudioFormatInfo(sampleRate: audio.sampleRate, channels: audio.channels,
                                                          bitDepth: audio.bitDepth, isFloat: audio.isFloat),
                        progress: progress)
                    let transcriptID = try await assemblyAI.createTranscript(request)
                    session.transcriptID = transcriptID
                    session.transcriptSubmittedAt = Date()
                    try database.save(session)
                    Log.pipeline.info("\(session.basename, privacy: .public): transcript \(transcriptID, privacy: .public)")
                    metadata.transcription = .init(
                        transcriptID: transcriptID, requestedModels: request.speechModels, languageCodes: request.languageCodes,
                        prompt: request.prompt, uploadedAudio: uploaded, submittedAt: session.transcriptSubmittedAt ?? Date())
                    try store.save(metadata, for: &session)
                }
                try enter(.transcribing)
                do {
                    let raw = try await waitForTranscript(session.transcriptID ?? "")
                    try raw.write(to: files.rawResponse, options: .atomic)
                } catch let error as ServiceError where error.kind == .jobFailed || error.kind == .rejected {
                    // This job is dead; a retry has to upload and submit again.
                    session.transcriptID = nil
                    throw error
                }
            }
            let transcript = try store.transcript(for: session)
            if metadata.transcription == nil {
                // Restarted between job creation and the metadata write, or adopted from files.
                metadata.transcription = .init(
                    transcriptID: session.transcriptID ?? transcript.id, requestedModels: AppConfig.AssemblyAI.speechModels,
                    languageCodes: AppConfig.AssemblyAI.languageCodes, prompt: nil,
                    submittedAt: session.transcriptSubmittedAt ?? Date())
            }
            if metadata.transcription?.completedAt == nil {
                metadata.transcription?.completedAt = Date()
                metadata.transcription?.modelUsed = transcript.modelUsed
                metadata.transcription?.languageDetected = transcript.languageCode
                metadata.transcription?.rawResponseFilename = files.rawResponse.lastPathComponent
                metadata.processing.stage = "transcribed"
                try store.save(metadata, for: &session)
            }

            // Speaker identity: an enhancement. Its failures become warnings, never a failed import.
            if metadata.processing.stage == "transcribed" {
                try enter(.analyzingSpeakers)
                let (analyzed, warnings) = await identity.analyze(
                    transcript: transcript, metadata: metadata, audio: audioURL, library: session.destinationPath)
                try Task.checkCancellation()
                metadata = analyzed
                metadata.processing.warnings = warnings
                metadata.processing.stage = "analyzed"
                try store.save(metadata, for: &session)
            }

            try enter(.generatingTranscript)
            try store.writeMarkdown(transcript: transcript, metadata: metadata, for: session)
            metadata.processing.stage = "complete"
            metadata.processing.processedAt = Date()
            try store.save(metadata, for: &session)

            session.stage = .complete
            session.lastActiveStage = nil
            try database.save(session)
            progress(ImportProgress(stage: .complete))
            Log.pipeline.info("\(session.basename, privacy: .public): complete in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")
        } catch {
            var stopped = error is CancellationError
            if case AudioMergeError.cancelled = error { stopped = true }
            session.stage = .failed
            session.lastActiveStage = active
            session.failure = stopped ? "Import was stopped. Resume to continue where it left off." : error.localizedDescription
            try? database.save(session)
            progress(ImportProgress(stage: .failed))
            Log.pipeline.error("\(session.basename, privacy: .public): failed while \(active.rawValue, privacy: .public): \(session.failure ?? "", privacy: .public)")
        }
    }

    /// Re-runs only the speaker analysis and Markdown generation for a finished session.
    func reanalyze(sessionID: String) async throws {
        guard var session = try database.session(id: sessionID) else { return }
        let transcript = try store.transcript(for: session)
        let (metadata, warnings) = await identity.analyze(
            transcript: transcript, metadata: try store.metadata(for: session), audio: store.audioURL(for: session),
            library: session.destinationPath)
        var updated = metadata
        updated.processing.warnings = warnings
        updated.processing.processedAt = Date()
        try store.writeMarkdown(transcript: transcript, metadata: updated, for: session)
        try store.save(updated, for: &session)
    }

    // MARK: Stages

    private func merge(_ session: inout ImportedSession, files: SessionFiles,
                       progress: @escaping @Sendable (ImportProgress) -> Void) async throws -> SessionMetadata {
        let urls = session.sources.map { URL(fileURLWithPath: $0.path) }
        guard !urls.isEmpty, urls.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }) else {
            throw ImportError.sourceUnavailable
        }
        // Re-inspect at import time: the chunks are the truth, not what an earlier scan saw.
        let recordings: [SourceRecording] = try session.sources.map { source in
            let url = URL(fileURLWithPath: source.path)
            let inspection = try AudioInspector.inspect(url)
            guard let parsed = DJIFilename(url.lastPathComponent) else {
                throw AudioInspectorError.unreadable(url.lastPathComponent)
            }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return SourceRecording(url: url, filename: url.lastPathComponent, transmitter: parsed.transmitter,
                                   variant: parsed.variant, sequence: parsed.sequence, start: source.start,
                                   frameCount: inspection.frameCount, fileSize: Int64(size), format: inspection.format)
        }
        let format = try AudioMerger.commonFormat(of: recordings)
        let container = AudioMerger.container(for: format)
        let partial = files.partialAudio(container)
        try? FileManager.default.removeItem(at: partial)

        let range = session.trim?.frames(sampleRate: format.sampleRate, totalFrames: recordings.reduce(0) { $0 + $1.frameCount })
        let merged: MergedAudio
        do {
            merged = try await Self.offCooperativePool {
                try AudioMerger.merge(sources: urls, format: format, to: partial, keeping: range) {
                    progress(ImportProgress(stage: .merging, fraction: $0))
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        let final = files.audio(container)
        // Same volume, so this rename is atomic. The name was verified free when the session was registered.
        _ = try FileManager.default.replaceItemAt(final, withItemAt: partial)

        // The same plan the merger followed, so clock times line up with the samples actually kept.
        let rate = format.sampleRate
        let sources = MergePlan.segments(frameCounts: recordings.map(\.frameCount), keeping: range).map { segment in
            let recording = recordings[segment.index]
            return SessionMetadata.Source(
                filename: recording.filename, start: recording.start, durationSeconds: recording.duration,
                frameCount: recording.frameCount, fileSizeBytes: recording.fileSize,
                offsetSeconds: Double(segment.outputOffset) / rate,
                skippedSeconds: segment.firstFrame > 0 ? Double(segment.firstFrame) / rate : nil)
        }
        let duration = Double(merged.frameCount) / rate
        let timeline = SessionTimeline(chunks: sources.map {
            .init(offsetSeconds: $0.offsetSeconds, start: $0.start.addingTimeInterval($0.skippedSeconds ?? 0))
        }, timeZone: .current)
        let untrimmed = recordings.reduce(0) { $0 + $1.duration }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let metadata = SessionMetadata(
            app: .init(name: AppConfig.appName, version: version),
            session: .init(id: session.id, fingerprint: session.fingerprint, start: timeline.date(atMs: 0),
                           end: timeline.date(atMs: Int((duration * 1000).rounded())), timeZone: session.timeZone,
                           recorderTimeZone: session.recorderTimeZone,
                           durationSeconds: duration, transmitter: session.transmitter,
                           trim: session.trim.map { .init(startSeconds: $0.start, endSeconds: min($0.end, untrimmed),
                                                          untrimmedDurationSeconds: untrimmed) }),
            sources: sources,
            audio: .init(filename: final.lastPathComponent, container: container, sampleRate: format.sampleRate,
                         channels: format.channels, bitDepth: format.bitDepth, isFloat: format.isFloat,
                         frameCount: merged.frameCount, pcmSHA256: merged.pcmSHA256),
            processing: .init(stage: "merged", processedAt: Date(), warnings: []))
        session.audioFilename = final.lastPathComponent
        try store.save(metadata, for: &session)
        return metadata
    }

    /// What gets uploaded for an archive: the archive itself when it is already 16 kHz / 16-bit or
    /// less, otherwise a 16 kHz / 16-bit FLAC rendition in a temporary file.
    ///
    /// AssemblyAI converts everything it receives to 16 kHz before transcribing, so the rendition
    /// carries the same information the service would use, at about a quarter of the upload size
    /// (a 30-minute 48 kHz / 24-bit chunk: 139 MB as archive FLAC, 31 MB as rendition). Lossy codecs
    /// would be smaller still but could cost accuracy; the archive in the library is never touched.
    static func uploadFile(for archive: URL, format: AudioFormatInfo) throws -> (url: URL, isRendition: Bool) {
        guard format.sampleRate > 16_000 || format.bitDepth > 16 || format.isFloat else { return (archive, false) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).flac")
        try AudioMerger.writeUploadProxy(from: archive, to: url)
        return (url, true)
    }

    /// Uploads the audio and returns the transcription request for it.
    private func upload(_ audio: URL, format: AudioFormatInfo,
                        progress: @escaping @Sendable (ImportProgress) -> Void) async throws -> (AssemblyAITranscriptRequest, uploaded: String) {
        let file = try await Self.offCooperativePool { try Self.uploadFile(for: audio, format: format) }
        defer { if file.isRendition { try? FileManager.default.removeItem(at: file.url) } }
        let bytes = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        Log.pipeline.info("Uploading \(bytes) bytes (\(file.isRendition ? "16 kHz rendition" : "archive", privacy: .public))")

        let uploadURL = try await retryingTransient {
            let started = Date()
            return try await assemblyAI.upload(file: file.url) { fraction in
                // Remaining time from the average rate so far, once there is enough of it to mean something.
                let elapsed = Date().timeIntervalSince(started)
                let remaining = elapsed >= 2 && fraction >= 0.02 ? elapsed / fraction * (1 - fraction) : nil
                progress(ImportProgress(stage: .uploading, fraction: fraction, remaining: remaining))
            }
        }
        let prompt = settings.transcriptionPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = AssemblyAITranscriptRequest(
            audioURL: uploadURL, speechModels: AppConfig.AssemblyAI.speechModels,
            languageCodes: AppConfig.AssemblyAI.languageCodes, prompt: prompt.isEmpty ? nil : prompt)
        return (request, file.isRendition ? "16 kHz 16-bit FLAC rendition of the archive" : "archive")
    }

    private func waitForTranscript(_ transcriptID: String) async throws -> Data {
        while true {
            let result = try await retryingTransient { try await assemblyAI.poll(transcriptID: transcriptID) }
            if case .completed(let raw) = result { return raw }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// Runs blocking audio work in its own task, forwarding cancellation to it.
    private static func offCooperativePool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: work)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Network hiccups, 5xx and rate limits are retried a few times with backoff before failing the stage.
    private func retryingTransient<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do { return try await operation() } catch let error as ServiceError where error.isTransient && attempt < 3 {
                attempt += 1
                try await Task.sleep(for: .seconds(min(error.retryAfter ?? Double(attempt * attempt * 2), 60)))
            }
        }
    }
}
