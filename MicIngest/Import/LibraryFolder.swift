import Foundation

/// A library folder: the place imports are written to, and at the same time the durable record of
/// everything imported. Plain files only, so it can live in a synced folder such as Google Drive
/// (a SQLite database there would be at the mercy of the sync client).
///
///     Library/
///       2026-10-01_20-43-49.md              one Markdown transcript per recording
///       Data/
///         2026-10-01_20-43-49.flac          merged audio
///         2026-10-01_20-43-49.assemblyai.json
///         2026-10-01_20-43-49.metadata.json
///         People.json                       known people and their voice profiles
///
/// The app's own database is an index of this folder plus in-progress state; `restore` rebuilds it.
struct LibraryFolder {
    static let dataFolderName = "Data"

    var root: URL
    var data: URL { root.appendingPathComponent(Self.dataFolderName, isDirectory: true) }
    var peopleFile: URL { data.appendingPathComponent("People.json") }

    // MARK: People

    /// `People.json`: everyone the app knows, with the voice samples recognition is based on.
    struct PeopleFile: Codable {
        struct Entry: Codable {
            var id: String
            var displayName: String
            var createdAt: Date
            var voiceSamples: [VoiceSample]
        }
        var schemaVersion = 1
        var people: [Entry]
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Writes this library's people and voice profiles into its folder (people of other libraries
    /// are not included). Does nothing for a folder that has no people file yet when there is nobody to write.
    func writePeople(from database: AppDatabase) throws {
        let people = try database.people(in: root.path)
        guard !people.isEmpty || FileManager.default.fileExists(atPath: peopleFile.path) else { return }
        let samples = Dictionary(grouping: try database.voiceSamples(library: root.path), by: \.personID)
        let file = PeopleFile(people: people.map {
            .init(id: $0.id, displayName: $0.displayName, createdAt: $0.createdAt,
                  voiceSamples: (samples[$0.id] ?? []).sorted { $0.createdAt < $1.createdAt })
        })
        let encoded = try Self.encoder.encode(file)
        // Leave the file alone when nothing changed, so a sync client has nothing to upload.
        guard (try? Data(contentsOf: peopleFile)) != encoded else { return }
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try encoded.write(to: peopleFile, options: .atomic)
    }

    /// Adds people and voice samples from the library that the database does not have yet.
    /// Returns how many records were added.
    // People are matched by ID only. Two Macs that each created "Sam" on their own end up with two
    // Sams; merge by name if the library is ever shared between machines that were set up separately.
    @discardableResult
    func mergePeople(into database: AppDatabase) throws -> Int {
        guard let encoded = try? Data(contentsOf: peopleFile) else { return 0 }
        let file = try Self.decoder.decode(PeopleFile.self, from: encoded)
        return try database.addMissing(
            people: file.people.map { Person(id: $0.id, displayName: $0.displayName, createdAt: $0.createdAt, library: root.path) },
            samples: file.people.flatMap(\.voiceSamples))
    }

    // MARK: Sessions

    /// Builds the database record for a session whose files are already in the library.
    static func record(adopting metadata: SessionMetadata, encoded: Data, files: SessionFiles) -> ImportedSession {
        let finished = metadata.processing.stage == "complete"
        let hasAudio = FileManager.default.fileExists(atPath: files.audio(named: metadata.audio.filename).path)
        let now = Date()
        return ImportedSession(
            id: metadata.session.id, fingerprint: metadata.session.fingerprint, transmitter: metadata.session.transmitter,
            start: metadata.session.start, end: metadata.session.end, timeZone: metadata.session.timeZone,
            recorderTimeZone: metadata.session.recorderTimeZone ?? metadata.session.timeZone, basename: files.basename,
            destinationPath: files.folder.path, destinationBookmark: FolderAccess.bookmark(for: files.folder),
            audioFilename: hasAudio ? metadata.audio.filename : nil,
            stage: finished ? .complete : .failed, lastActiveStage: nil,
            failure: finished ? nil : "This import was not finished. Resume to continue where it left off.",
            transcriptID: metadata.transcription?.transcriptID, transcriptSubmittedAt: metadata.transcription?.submittedAt,
            sources: [], metadataJSON: encoded, createdAt: now, updatedAt: now)
    }

    /// Makes every session found in the library known to the database again: after the app's data was
    /// deleted, on a new Mac, or when a library folder is opened for the first time. Sessions the
    /// database already has are left untouched. Returns how many were added.
    @discardableResult
    func restoreSessions(into database: AppDatabase) throws -> Int {
        let suffix = ".metadata.json"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: data.path)) ?? [])
            .filter { $0.hasSuffix(suffix) && !$0.hasPrefix(".") }.sorted()
        guard !names.isEmpty else { return 0 }
        let known = try database.sessions()
        var ids = Set(known.map(\.id)), fingerprints = Set(known.map(\.fingerprint))
        var added = 0
        for name in names {
            let files = SessionFiles(folder: root, basename: String(name.dropLast(suffix.count)))
            guard let encoded = try? Data(contentsOf: files.metadata),
                  let metadata = try? SessionMetadata.decode(encoded),
                  !ids.contains(metadata.session.id), !fingerprints.contains(metadata.session.fingerprint) else { continue }
            // Speakers keep their names even if the people file is missing.
            try database.addMissing(people: metadata.speakers.compactMap { speaker in
                speaker.personID.map {
                    Person(id: $0, displayName: speaker.displayName, createdAt: metadata.processing.processedAt, library: root.path)
                }
            }, samples: [])
            try database.insert(
                Self.record(adopting: metadata, encoded: encoded, files: files),
                sourceFingerprints: metadata.sources.map {
                    SourceRecording.fingerprint(filename: $0.filename, fileSize: $0.fileSizeBytes, frameCount: $0.frameCount)
                })
            ids.insert(metadata.session.id)
            fingerprints.insert(metadata.session.fingerprint)
            added += 1
        }
        Log.persistence.info("Restored \(added) of \(names.count) sessions from the library folder")
        return added
    }
}
