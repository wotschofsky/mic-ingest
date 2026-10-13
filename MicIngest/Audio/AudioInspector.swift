import AVFoundation

/// The PCM characteristics that decide whether chunks can be merged and how the archive is stored.
struct AudioFormatInfo: Codable, Hashable {
    var sampleRate: Double
    var channels: Int
    var bitDepth: Int
    var isFloat: Bool

    var summary: String {
        let rate = sampleRate.truncatingRemainder(dividingBy: 1000) == 0
            ? "\(Int(sampleRate / 1000)) kHz" : String(format: "%.1f kHz", sampleRate / 1000)
        let layout = channels == 1 ? "mono" : channels == 2 ? "stereo" : "\(channels) ch"
        return "\(rate) · \(bitDepth)-bit \(isFloat ? "float" : "PCM") · \(layout)"
    }
}

struct AudioInspection {
    var format: AudioFormatInfo
    var frameCount: Int64
    var duration: TimeInterval { Double(frameCount) / format.sampleRate }
}

enum AudioInspectorError: LocalizedError {
    case unreadable(String)
    case notLinearPCM(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "Could not read recording duration of \(name)."
        case .notLinearPCM(let name): "\(name) is not an uncompressed PCM recording."
        }
    }
}

/// A file whose header cannot be read (e.g. the recorder lost power before finishing it) is reported
/// as unreadable and skipped. Recovering it by guessing the format and length from the file size was
/// considered and rejected: it would mean presenting invented durations as facts.
enum AudioInspector {
    /// Reads format and exact frame count from the file's audio header (never from file size or dates).
    static func inspect(_ url: URL) throws -> AudioInspection {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw AudioInspectorError.unreadable(url.lastPathComponent)
        }
        let description = file.fileFormat.streamDescription.pointee
        guard description.mFormatID == kAudioFormatLinearPCM else {
            throw AudioInspectorError.notLinearPCM(url.lastPathComponent)
        }
        guard file.length > 0, description.mSampleRate > 0 else {
            throw AudioInspectorError.unreadable(url.lastPathComponent)
        }
        let format = AudioFormatInfo(
            sampleRate: description.mSampleRate,
            channels: Int(description.mChannelsPerFrame),
            bitDepth: Int(description.mBitsPerChannel),
            isFloat: description.mFormatFlags & kAudioFormatFlagIsFloat != 0)
        return AudioInspection(format: format, frameCount: file.length)
    }
}
