import Foundation

struct SourceScan {
    var recordings: [SourceRecording] = []
    var problems: [SourceProblem] = []
}

/// Finds DJI recordings in a folder and inspects their audio headers. Strictly read-only.
enum SourceScanner {
    /// DJI recorders keep recordings at the top of the volume or one or two folders down.
    static let maxDepth = 3

    static func recordingURLs(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            if enumerator.level > maxDepth { enumerator.skipDescendants(); continue }
            if DJIFilename(url.lastPathComponent) != nil { urls.append(url) }
        }
        return urls
    }

    /// Cheap check used for mounted volumes before presenting them as a source.
    static func containsRecordings(_ folder: URL) -> Bool {
        !recordingURLs(in: folder).isEmpty
    }

    static func scan(_ folder: URL, timeZone: TimeZone = .current) async -> SourceScan {
        await Task.detached(priority: .userInitiated) {
            var scan = SourceScan()
            for url in recordingURLs(in: folder) {
                if Task.isCancelled { break }
                let name = url.lastPathComponent
                guard let parsed = DJIFilename(name), let start = parsed.startDate(in: timeZone) else { continue }
                do {
                    let inspection = try AudioInspector.inspect(url)
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    scan.recordings.append(SourceRecording(
                        url: url, filename: name, transmitter: parsed.transmitter, variant: parsed.variant, sequence: parsed.sequence,
                        start: start, frameCount: inspection.frameCount, fileSize: Int64(size),
                        format: inspection.format))
                } catch {
                    scan.problems.append(SourceProblem(filename: name, message: error.localizedDescription))
                }
            }
            scan.problems.sort { $0.filename < $1.filename }
            Log.source.info("Scanned source: \(scan.recordings.count) recordings, \(scan.problems.count) unreadable")
            return scan
        }.value
    }
}
