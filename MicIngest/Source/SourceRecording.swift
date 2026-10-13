import Foundation

/// One WAV chunk on the recorder. Read-only: nothing in the app writes to `url`.
struct SourceRecording: Identifiable, Hashable {
    var url: URL
    var filename: String
    var transmitter: String
    var variant: String = ""
    var sequence: Int
    var start: Date
    var frameCount: Int64
    var fileSize: Int64
    var format: AudioFormatInfo

    var duration: TimeInterval { Double(frameCount) / format.sampleRate }
    var end: Date { start.addingTimeInterval(duration) }

    /// Cheap, stable identity of the source material: name + byte size + exact frame count.
    /// Hashing gigabytes on every scan is not needed; these three do not collide in practice.
    var fingerprint: String { Self.fingerprint(filename: filename, fileSize: fileSize, frameCount: frameCount) }

    static func fingerprint(filename: String, fileSize: Int64, frameCount: Int64) -> String {
        "\(filename.lowercased())|\(fileSize)|\(frameCount)"
    }
    var id: String { fingerprint }
}

/// A file that looked like a DJI recording but could not be used.
struct SourceProblem: Identifiable, Hashable {
    var filename: String
    var message: String
    var id: String { filename }
}
