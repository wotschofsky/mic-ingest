import Foundation
import XCTest
@testable import MicIngest

let berlin = TimeZone(identifier: "Europe/Berlin")!

func date(_ string: String, in timeZone: TimeZone = berlin) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.date(from: string)!
}

let testFormat = AudioFormatInfo(sampleRate: 48_000, channels: 1, bitDepth: 24, isFloat: false)

/// A recording as the scanner would produce it, without touching the disk.
func recording(_ filename: String, seconds: Double, format: AudioFormatInfo = testFormat) -> SourceRecording {
    let parsed = DJIFilename(filename)!
    let frames = Int64(seconds * format.sampleRate)
    return SourceRecording(
        url: URL(fileURLWithPath: "/Volumes/DJI/\(filename)"), filename: filename,
        transmitter: parsed.transmitter, variant: parsed.variant, sequence: parsed.sequence,
        start: parsed.startDate(in: berlin)!, frameCount: frames,
        fileSize: frames * 3 + 44, format: format)
}

/// The recorder contents from the product brief.
func briefRecordings() -> [SourceRecording] {
    [
        recording("TX01_MIC001_20261001_193402_orig.wav", seconds: 754),
        recording("TX01_MIC002_20261001_204349_orig.wav", seconds: 1800.6),
        recording("TX01_MIC003_20261001_211350_orig.wav", seconds: 1800),
        recording("TX01_MIC004_20261001_214350_orig.wav", seconds: 1800),
        recording("TX01_MIC005_20261001_221350_orig.wav", seconds: 1800),
        recording("TX01_MIC006_20261001_224350_orig.wav", seconds: 497),
        recording("TX01_MIC007_20261001_232928_orig.wav", seconds: 9.4),
        recording("TX01_MIC008_20261001_232938_orig.wav", seconds: 1.8),
        recording("TX01_MIC009_20261001_232940_orig.wav", seconds: 3),
        recording("TX01_MIC010_20261001_233414_orig.wav", seconds: 1800),
        recording("TX01_MIC011_20261002_000414_orig.wav", seconds: 1433),
    ]
}

/// Writes a small PCM WAV (sine tone) for tests that need real audio files.
func writeWAV(to url: URL, seconds: Double, sampleRate: Double = 8000, bitDepth: Int = 16,
              isFloat: Bool = false, channels: Int = 1, frequency: Double = 220, repeatingBlock: Bool = false) throws {
    let frames = Int(seconds * sampleRate)
    let bytesPerSample = bitDepth / 8
    var data = Data(capacity: frames * channels * bytesPerSample)
    // For long files, synthesize one second and repeat it (sample-by-sample generation is slow in debug builds).
    let generated = repeatingBlock ? min(frames, Int(sampleRate)) : frames
    for frame in 0..<generated {
        // Deterministic but non-trivial signal: tone plus a slow ramp so every bit of the sample is exercised.
        let value = sin(2 * .pi * frequency * Double(frame) / sampleRate) * 0.6 + Double(frame % 97) / 970 - 0.05
        for _ in 0..<channels {
            if isFloat {
                var sample = Float(value).bitPattern.littleEndian
                withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
            } else {
                let scaled = Int64(value * Double(Int64(1) << (bitDepth - 1)))
                var little = scaled.littleEndian
                withUnsafeBytes(of: &little) { data.append(contentsOf: $0.prefix(bytesPerSample)) }
            }
        }
    }
    if generated < frames {
        let block = data
        for _ in 1..<(frames / generated) { data.append(block) }
        data.append(block.prefix((frames % generated) * channels * bytesPerSample))
    }
    var header = Data()
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
    header.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + data.count))
    header.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
    append(UInt16(isFloat ? 3 : 1)); append(UInt16(channels)); append(UInt32(sampleRate))
    append(UInt32(Int(sampleRate) * channels * bytesPerSample)); append(UInt16(channels * bytesPerSample)); append(UInt16(bitDepth))
    header.append(contentsOf: Array("data".utf8)); append(UInt32(data.count))
    try (header + data).write(to: url)
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("MicIngestTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
