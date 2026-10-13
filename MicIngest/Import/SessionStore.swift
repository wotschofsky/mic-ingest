import Foundation

enum SessionStoreError: LocalizedError {
    case metadataMissing(String)
    case transcriptMissing(String)

    var errorDescription: String? {
        switch self {
        case .metadataMissing(let name): "The metadata for \(name) could not be found. Is the destination folder available?"
        case .transcriptMissing(let name): "The transcript for \(name) could not be found. Is the destination folder available?"
        }
    }
}

/// Reads and writes a session's exported files, and keeps the database copy of its metadata in step.
/// The files in the destination folder are the source of truth; the database copy is the fallback.
struct SessionStore {
    var database: AppDatabase

    func files(for session: ImportedSession) -> SessionFiles {
        let folder = FolderAccess.resolve(session.destinationBookmark) ?? session.destination
        return SessionFiles(folder: folder, basename: session.basename)
    }

    func audioURL(for session: ImportedSession) -> URL? {
        session.audioFilename.map { files(for: session).audio(named: $0) }
    }

    func metadata(for session: ImportedSession) throws -> SessionMetadata {
        if let data = try? Data(contentsOf: files(for: session).metadata), let metadata = try? SessionMetadata.decode(data) {
            return metadata
        }
        guard let data = session.metadataJSON else { throw SessionStoreError.metadataMissing(session.basename) }
        return try SessionMetadata.decode(data)
    }

    func transcript(for session: ImportedSession) throws -> Transcript {
        guard let data = try? Data(contentsOf: files(for: session).rawResponse) else {
            throw SessionStoreError.transcriptMissing(session.basename)
        }
        return try Transcript(rawResponse: data)
    }

    /// Writes `*.metadata.json` (atomically) and mirrors it into the database.
    func save(_ metadata: SessionMetadata, for session: inout ImportedSession) throws {
        let data = try metadata.encoded()
        try data.write(to: files(for: session).metadata, options: .atomic)
        session.metadataJSON = data
        try database.save(session)
    }

    /// Moves a session written by an earlier build, which put every file loose into the folder,
    /// into the library layout: data files into `Data`, Markdown rewritten with its header.
    func migrateLegacyLayout(_ session: ImportedSession) {
        let files = files(for: session)
        let manager = FileManager.default
        var moves = [("\(session.basename).metadata.json", files.metadata),
                     ("\(session.basename).assemblyai.json", files.rawResponse)]
        if let audio = session.audioFilename { moves.append((audio, files.audio(named: audio))) }
        let pending = moves.map { (files.folder.appendingPathComponent($0.0), $0.1) }
            .filter { manager.fileExists(atPath: $0.0.path) && !manager.fileExists(atPath: $0.1.path) }
        guard !pending.isEmpty else { return }
        do {
            try manager.createDirectory(at: files.data, withIntermediateDirectories: true)
            for (old, new) in pending { try manager.moveItem(at: old, to: new) }
            if manager.fileExists(atPath: files.markdown.path) {
                try writeMarkdown(transcript: transcript(for: session), metadata: metadata(for: session), for: session)
            }
            Log.persistence.info("Moved \(session.basename, privacy: .public) into the library layout")
        } catch {
            Log.persistence.error("Could not move \(session.basename, privacy: .public) into the library layout: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Moves the session's transcript, audio and data files to the Trash and forgets the session.
    /// Recoverable from the Trash; the recorder is not involved. (`discard` is replaceable so tests
    /// do not fill the real Trash.)
    func trash(_ session: ImportedSession,
               discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        let files = files(for: session)
        var urls = [files.markdown, files.rawResponse, files.metadata]
        if let audio = session.audioFilename { urls.append(files.audio(named: audio)) }
        for url in urls where FileManager.default.fileExists(atPath: url.path) { try discard(url) }
        try database.deleteSession(id: session.id)
    }

    /// Regenerates the Markdown transcript from the raw response and the current metadata.
    func writeMarkdown(transcript: Transcript, metadata: SessionMetadata, for session: ImportedSession) throws {
        let markdown = MarkdownRenderer.render(transcript: transcript, metadata: metadata)
        try Data(markdown.utf8).write(to: files(for: session).markdown, options: .atomic)
    }
}
