import Foundation

/// The files one imported session consists of, all sharing a basename. The Markdown transcript sits
/// at the top of the library folder (so the folder reads as a list of transcripts, for people and
/// for LLMs alike); audio, raw response and metadata sit in its `Data` subfolder.
struct SessionFiles: Equatable {
    /// The library folder.
    var folder: URL
    var basename: String

    var data: URL { LibraryFolder(root: folder).data }
    func audio(_ container: ArchiveContainer) -> URL { data.appendingPathComponent("\(basename).\(container.fileExtension)") }
    func audio(named filename: String) -> URL { data.appendingPathComponent(filename) }
    var markdown: URL { folder.appendingPathComponent("\(basename).md") }
    var rawResponse: URL { data.appendingPathComponent("\(basename).assemblyai.json") }
    var metadata: URL { data.appendingPathComponent("\(basename).metadata.json") }

    /// Hidden while being written; renamed into place only once verified.
    func partialAudio(_ container: ArchiveContainer) -> URL {
        data.appendingPathComponent(".\(basename).partial.\(container.fileExtension)")
    }

    private var existingFiles: [URL] {
        ([markdown, rawResponse, metadata] + [ArchiveContainer.flac, .wav].map(audio))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// `2026-10-01_20-43-49`, from the session start in its own time zone.
    static func basename(for start: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        return String(format: "%04d-%02d-%02d_%02d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0, p.hour ?? 0, p.minute ?? 0, p.second ?? 0)
    }

    enum Placement: Equatable {
        /// Nothing with this name exists yet.
        case new(SessionFiles)
        /// The folder already holds an import of exactly this session.
        case existing(SessionFiles)
    }

    /// Finds where a session's files go. Never reuses a name taken by anything other than a previous
    /// import of the same session; unrelated files are left alone and a numeric suffix is added instead.
    static func place(start: Date, timeZone: TimeZone, fingerprint: String, in folder: URL) -> Placement {
        let base = basename(for: start, in: timeZone)
        for attempt in 1...999 {
            let files = SessionFiles(folder: folder, basename: attempt == 1 ? base : "\(base)-\(attempt)")
            if files.existingFiles.isEmpty { return .new(files) }
            if let data = try? Data(contentsOf: files.metadata),
               let metadata = try? SessionMetadata.decode(data), metadata.session.fingerprint == fingerprint {
                return .existing(files)
            }
        }
        return .new(SessionFiles(folder: folder, basename: "\(base)-\(UUID().uuidString.prefix(8))"))
    }
}

/// Remembers folders the user picked. The app is not sandboxed, so plain paths work; the
/// security-scoped bookmark additionally survives the folder being moved or renamed.
enum FolderAccess {
    static func bookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData())
    }

    static func resolve(_ bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        return (try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale))
    }

    /// Runs `body` with access to `url` (a no-op outside the sandbox).
    static func withAccess<T>(to url: URL, _ body: () async throws -> T) async rethrows -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try await body()
    }
}
