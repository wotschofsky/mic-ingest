import Foundation
import GRDB

/// Explicit pipeline stages. The raw value is persisted, so a restart knows where a session stopped.
enum ImportStage: String, Codable, CaseIterable {
    case preparing, merging, uploading, transcribing, analyzingSpeakers, generatingTranscript, complete, failed

    var title: String {
        switch self {
        case .preparing: "Preparing"
        case .merging: "Merging"
        case .uploading: "Uploading"
        case .transcribing: "Transcribing"
        case .analyzingSpeakers: "Analyzing speakers"
        case .generatingTranscript: "Generating transcript"
        case .complete: "Complete"
        case .failed: "Failed"
        }
    }
}

/// One imported (or importing) session. Small state only; audio stays in the destination folder.
struct ImportedSession: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "importedSession"

    var id: String
    var fingerprint: String
    var transmitter: String
    var start: Date
    var end: Date
    /// Zone the session's clock times are shown in (where the import happened).
    var timeZone: String
    /// Zone the recorder's own clock runs in; its filename timestamps were read in this zone.
    var recorderTimeZone: String
    var basename: String
    var destinationPath: String
    var destinationBookmark: Data?
    var audioFilename: String?
    var stage: ImportStage
    /// Stage that was running when the session failed or the app quit.
    var lastActiveStage: ImportStage?
    var failure: String?
    var transcriptID: String?
    var transcriptSubmittedAt: Date?
    /// Source chunks with their start instants, needed only until the audio is merged.
    var sources: [SourceReference]
    /// The part of the session to import, if its ends were trimmed (seconds from its first sample).
    var trimStart: Double?
    var trimEnd: Double?

    var trim: Trim? {
        guard let trimStart, let trimEnd else { return nil }
        return Trim(start: trimStart, end: trimEnd)
    }
    /// Copy of the latest `*.metadata.json`, so identity state survives a missing destination folder.
    var metadataJSON: Data?
    var createdAt: Date
    var updatedAt: Date

    var destination: URL { URL(fileURLWithPath: destinationPath, isDirectory: true) }
    var duration: TimeInterval { end.timeIntervalSince(start) }
    var isFinished: Bool { stage == .complete }
}

struct SourceReference: Codable, Hashable {
    var path: String
    var start: Date
}

/// A source chunk that belongs to an imported session, for duplicate detection on later scans.
struct ImportedSource: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "importedSource"
    var fingerprint: String
    var sessionID: String
}

/// A trim set on the import screen, keyed by the session's fingerprint, so it survives rescans.
struct SessionTrimRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sessionTrim"
    var fingerprint: String
    var start: Double
    var end: Double
}

struct BoundaryOverrideRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "boundaryOverride"
    var fingerprint: String
    var kind: BoundaryOverride
}

/// One representative embedding in a person's voice profile. Embeddings never leave this database.
struct VoiceSample: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "voiceSample"

    var id: String
    var personID: String
    var modelVersion: String
    var embedding: Data
    var provenance: EmbeddingProvenance
    var sessionID: String
    var speakerLabel: String
    var speechSeconds: Double
    var createdAt: Date

    var vector: [Float] {
        embedding.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func data(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

extension Person: FetchableRecord, PersistableRecord {
    static let databaseTableName = "person"
}

/// SQLite via GRDB (MIT): typed records, migrations and change observation without hand-written SQL glue.
struct AppDatabase {
    let queue: DatabaseQueue
    var fileURL: URL? { queue.path == ":memory:" ? nil : URL(fileURLWithPath: queue.path) }

    init(_ queue: DatabaseQueue) throws {
        self.queue = queue
        try Self.migrator.migrate(queue)
    }

    static func inMemory() throws -> AppDatabase { try AppDatabase(DatabaseQueue()) }

    /// The database in Application Support. A profile (debug builds only) gets its own folder.
    static func onDisk(profile: String? = nil) throws -> AppDatabase {
        let folder = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(AppConfig.appName + (profile.map { "-\($0)" } ?? ""), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(AppConfig.appName).sqlite")
        Log.persistence.info("Opening database at \(url.path, privacy: .public)")
        return try AppDatabase(DatabaseQueue(path: url.path))
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "person") { t in
                t.primaryKey("id", .text)
                t.column("displayName", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "voiceSample") { t in
                t.primaryKey("id", .text)
                t.column("personID", .text).notNull().indexed().references("person", onDelete: .cascade)
                t.column("modelVersion", .text).notNull()
                t.column("embedding", .blob).notNull()
                t.column("provenance", .text).notNull()
                t.column("sessionID", .text).notNull()
                t.column("speakerLabel", .text).notNull()
                t.column("speechSeconds", .double).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "importedSession") { t in
                t.primaryKey("id", .text)
                t.column("fingerprint", .text).notNull().indexed()
                t.column("transmitter", .text).notNull()
                t.column("start", .datetime).notNull()
                t.column("end", .datetime).notNull()
                t.column("timeZone", .text).notNull()
                t.column("recorderTimeZone", .text).notNull()
                t.column("basename", .text).notNull()
                t.column("destinationPath", .text).notNull()
                t.column("destinationBookmark", .blob)
                t.column("audioFilename", .text)
                t.column("stage", .text).notNull()
                t.column("lastActiveStage", .text)
                t.column("failure", .text)
                t.column("transcriptID", .text)
                t.column("transcriptSubmittedAt", .datetime)
                t.column("sources", .jsonText).notNull()
                t.column("metadataJSON", .blob)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "importedSource") { t in
                t.column("fingerprint", .text).notNull().indexed()
                t.column("sessionID", .text).notNull().references("importedSession", onDelete: .cascade)
                t.primaryKey(["fingerprint", "sessionID"])
            }
            try db.create(table: "boundaryOverride") { t in
                t.primaryKey("fingerprint", .text)
                t.column("kind", .text).notNull()
            }
        }
        migrator.registerMigration("v2-people-per-library") { db in
            try db.alter(table: "person") { t in
                t.add(column: "library", .text).notNull().defaults(to: "")
            }
        }
        migrator.registerMigration("v3-trim") { db in
            try db.create(table: "sessionTrim") { t in
                t.primaryKey("fingerprint", .text)
                t.column("start", .double).notNull()
                t.column("end", .double).notNull()
            }
            try db.alter(table: "importedSession") { t in
                t.add(column: "trimStart", .double)
                t.add(column: "trimEnd", .double)
            }
        }
        return migrator
    }

    // MARK: Sessions

    func sessions() throws -> [ImportedSession] {
        try queue.read { try ImportedSession.order(Column("start").desc).fetchAll($0) }
    }

    /// Forgets a library: its sessions and people leave the database. The folder itself is not touched.
    func removeLibrary(path: String) throws {
        try queue.write { db in
            _ = try ImportedSession.filter(Column("destinationPath") == path).deleteAll(db)
            _ = try Person.filter(Column("library") == path).deleteAll(db)
        }
    }

    /// People created before libraries existed belong to the library that was in use then.
    func adoptPeopleWithoutLibrary(into path: String) throws {
        try queue.write { _ = try Person.filter(Column("library") == "").updateAll($0, Column("library").set(to: path)) }
    }

    func session(id: String) throws -> ImportedSession? {
        try queue.read { try ImportedSession.fetchOne($0, key: id) }
    }

    func save(_ session: ImportedSession) throws {
        var session = session
        session.updatedAt = Date()
        try queue.write { try session.save($0) }
    }

    /// Records a new session together with the source chunks it covers.
    func insert(_ session: ImportedSession, sourceFingerprints: [String]) throws {
        try queue.write { db in
            try session.save(db)
            for fingerprint in sourceFingerprints {
                try ImportedSource(fingerprint: fingerprint, sessionID: session.id).save(db)
            }
        }
    }

    /// Forgets the session. Exported files and learned voice profiles are left alone.
    func deleteSession(id: String) throws {
        try queue.write { _ = try ImportedSession.deleteOne($0, key: id) }
    }

    /// Source fingerprint → ID of the session it was imported with.
    func importedSources() throws -> [String: String] {
        try queue.read { db in
            Dictionary(try ImportedSource.fetchAll(db).map { ($0.fingerprint, $0.sessionID) }, uniquingKeysWith: { a, _ in a })
        }
    }

    func observeSessions() -> AsyncValueObservation<[ImportedSession]> {
        ValueObservation.tracking { try ImportedSession.order(Column("start").desc).fetchAll($0) }.values(in: queue)
    }

    // MARK: Trims

    func trims() throws -> [String: Trim] {
        try queue.read { db in
            Dictionary(uniqueKeysWithValues: try SessionTrimRecord.fetchAll(db).map { ($0.fingerprint, Trim(start: $0.start, end: $0.end)) })
        }
    }

    func setTrim(_ trim: Trim?, for fingerprint: String) throws {
        try queue.write { db in
            if let trim {
                try SessionTrimRecord(fingerprint: fingerprint, start: trim.start, end: trim.end).save(db)
            } else {
                _ = try SessionTrimRecord.deleteOne(db, key: fingerprint)
            }
        }
    }

    // MARK: Grouping overrides

    func boundaryOverrides() throws -> [String: BoundaryOverride] {
        try queue.read { db in
            Dictionary(uniqueKeysWithValues: try BoundaryOverrideRecord.fetchAll(db).map { ($0.fingerprint, $0.kind) })
        }
    }

    func setBoundaryOverride(_ kind: BoundaryOverride?, for fingerprint: String) throws {
        try queue.write { db in
            if let kind {
                try BoundaryOverrideRecord(fingerprint: fingerprint, kind: kind).save(db)
            } else {
                _ = try BoundaryOverrideRecord.deleteOne(db, key: fingerprint)
            }
        }
    }

    // MARK: People and voice profiles

    /// Known people, by name. With `library`, only the people of that library folder.
    func people(in library: String? = nil) throws -> [Person] {
        try queue.read { db in
            var request = Person.order(Column("displayName").collating(.localizedCaseInsensitiveCompare))
            if let library { request = request.filter(Column("library") == library) }
            return try request.fetchAll(db)
        }
    }

    func observePeople() -> AsyncValueObservation<[Person]> {
        ValueObservation.tracking {
            try Person.order(Column("displayName").collating(.localizedCaseInsensitiveCompare)).fetchAll($0)
        }.values(in: queue)
    }

    func person(id: String) throws -> Person? {
        try queue.read { try Person.fetchOne($0, key: id) }
    }

    @discardableResult
    func createPerson(named name: String, library: String = "") throws -> Person {
        let person = Person(id: UUID().uuidString, displayName: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            createdAt: Date(), library: library)
        try queue.write { try person.insert($0) }
        return person
    }

    func rename(personID: String, to name: String) throws {
        try queue.write { db in
            guard var person = try Person.fetchOne(db, key: personID) else { return }
            person.displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            try person.update(db)
        }
    }

    /// Deletes the person and, by cascade, all of their voice data.
    func deletePerson(id: String) throws {
        try queue.write { _ = try Person.deleteOne($0, key: id) }
    }

    /// Voice samples for one embedding model. With `library`, only those of that library's people.
    func voiceSamples(modelVersion: String? = nil, library: String? = nil) throws -> [VoiceSample] {
        try queue.read { db in
            var request = VoiceSample.all()
            if let modelVersion { request = request.filter(Column("modelVersion") == modelVersion) }
            if let library {
                request = request.filter(Person.select(Column("id")).filter(Column("library") == library).contains(Column("personID")))
            }
            return try request.fetchAll(db)
        }
    }

    /// Inserts the people and voice samples that are not in the database yet (matched by ID).
    @discardableResult
    func addMissing(people: [Person], samples: [VoiceSample]) throws -> Int {
        guard !people.isEmpty || !samples.isEmpty else { return 0 }
        return try queue.write { db in
            var added = 0
            for person in people where try Person.fetchOne(db, key: person.id) == nil {
                try person.insert(db)
                added += 1
            }
            for sample in samples
            where try VoiceSample.fetchOne(db, key: sample.id) == nil && Person.fetchOne(db, key: sample.personID) != nil {
                try sample.insert(db)
                added += 1
            }
            return added
        }
    }

    /// Emits whenever people or voice samples change.
    func observeVoiceProfiles() -> AsyncValueObservation<Int> {
        ValueObservation.tracking(regions: [Person.all(), VoiceSample.all()]) {
            try Person.fetchCount($0) + VoiceSample.fetchCount($0)
        }.values(in: queue)
    }

    func voiceSampleCounts() throws -> [String: Int] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT personID, COUNT(*) AS n FROM voiceSample GROUP BY personID")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["personID"] as String, $0["n"] as Int) })
        }
    }

    func deleteVoiceSamples(personID: String) throws {
        try queue.write { _ = try VoiceSample.filter(Column("personID") == personID).deleteAll($0) }
    }

    /// Replaces whatever this session's speaker contributed before with the given sample (or nothing).
    /// Keeps a profile free of audio from a cluster whose identity was changed or removed.
    func replaceVoiceSample(sessionID: String, speakerLabel: String, with sample: VoiceSample?, limitPerPerson: Int) throws {
        try queue.write { db in
            _ = try VoiceSample
                .filter(Column("sessionID") == sessionID && Column("speakerLabel") == speakerLabel)
                .deleteAll(db)
            guard let sample else { return }
            try sample.insert(db)
            // Bounded profile: when full, drop the oldest automatically enrolled samples first and
            // never a manually confirmed one unless nothing else is left.
            let all = try VoiceSample
                .filter(Column("personID") == sample.personID && Column("modelVersion") == sample.modelVersion)
                .order(Column("createdAt"))
                .fetchAll(db)
            var excess = all.count - limitPerPerson
            for candidate in all.filter({ $0.provenance == .highConfidenceVoiceMatch }) + all.filter({ $0.provenance != .highConfidenceVoiceMatch })
            where excess > 0 && candidate.id != sample.id {
                _ = try VoiceSample.deleteOne(db, key: candidate.id)
                excess -= 1
            }
        }
    }
}
