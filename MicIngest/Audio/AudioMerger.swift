import AVFoundation
import CryptoKit

enum ArchiveContainer: String, Codable {
    case flac, wav
    var fileExtension: String { rawValue }
}

struct MergedAudio {
    var container: ArchiveContainer
    var format: AudioFormatInfo
    var frameCount: Int64
    /// SHA-256 of the interleaved PCM samples. The same value is recomputed from the written file.
    var pcmSHA256: String
}

enum AudioMergeError: LocalizedError {
    case nothingToMerge
    case incompatibleFormats(String)
    case verificationFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .nothingToMerge:
            "The session has no source recordings."
        case .incompatibleFormats(let detail):
            "The recordings in this session use different audio formats (\(detail)) and cannot be merged without altering the audio. Split the session and import the parts separately."
        case .verificationFailed:
            "The merged audio did not match the source recordings when read back. Nothing was kept; try again."
        case .cancelled:
            "Import was cancelled."
        }
    }
}

/// Concatenates source chunks sample-for-sample into one lossless archive file.
///
/// - Integer PCM up to 24 bit → FLAC at the source sample rate, channel count and bit depth.
/// - Floating-point PCM (and 32-bit integer, which Apple's FLAC encoder does not take) → WAV in the
///   source sample format. Converting float to integer would not be lossless, so it is never done.
/// - Chunks with differing formats are refused rather than converted.
///
/// The written file is decoded again and compared against a hash of the source samples before it is kept.
enum AudioMerger {
    static func container(for format: AudioFormatInfo) -> ArchiveContainer {
        !format.isFloat && format.bitDepth <= 24 ? .flac : .wav
    }

    static func commonFormat(of recordings: [SourceRecording]) throws -> AudioFormatInfo {
        guard let first = recordings.first?.format else { throw AudioMergeError.nothingToMerge }
        let formats = Set(recordings.map(\.format))
        guard formats.count == 1 else {
            throw AudioMergeError.incompatibleFormats(formats.map(\.summary).sorted().joined(separator: " / "))
        }
        return first
    }

    /// Sample type used in memory. Chosen so that every source sample value is represented exactly.
    private static func processingFormat(for format: AudioFormatInfo) -> AVAudioFormat? {
        let common: AVAudioCommonFormat =
            format.isFloat ? (format.bitDepth > 32 ? .pcmFormatFloat64 : .pcmFormatFloat32)
            : (format.bitDepth <= 16 ? .pcmFormatInt16 : .pcmFormatInt32)
        return AVAudioFormat(commonFormat: common, sampleRate: format.sampleRate,
                             channels: AVAudioChannelCount(format.channels), interleaved: true)
    }

    private static func writerSettings(for format: AudioFormatInfo, container: ArchiveContainer, totalFrames: Int64) -> [String: Any] {
        var settings: [String: Any] = [
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channels,
        ]
        switch container {
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
            settings[AVEncoderBitDepthHintKey] = format.bitDepth
        case .wav:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = format.bitDepth
            settings[AVLinearPCMIsFloatKey] = format.isFloat
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
            // Plain WAV stops at 4 GB; RF64 is the same format with 64-bit sizes.
            let bytes = totalFrames * Int64(format.channels * format.bitDepth / 8)
            if bytes > 3_900_000_000 { settings[AVAudioFileTypeKey] = kAudioFileRF64Type }
        }
        return settings
    }

    /// Merges `sources` into `destination` (which must not exist), keeping only `range` of the
    /// concatenated frames if given (a trimmed session). Blocking; call off the main actor.
    static func merge(sources: [URL], format: AudioFormatInfo, to destination: URL, keeping range: Range<Int64>? = nil,
                      progress: @escaping (Double) -> Void = { _ in }) throws -> MergedAudio {
        guard !sources.isEmpty else { throw AudioMergeError.nothingToMerge }
        guard let processing = processingFormat(for: format) else {
            throw AudioMergeError.incompatibleFormats(format.summary)
        }
        let container = container(for: format)
        let inputs = try sources.map {
            try AVAudioFile(forReading: $0, commonFormat: processing.commonFormat, interleaved: true)
        }
        let segments = MergePlan.segments(frameCounts: inputs.map(\.length), keeping: range)
        let totalFrames = segments.reduce(Int64(0)) { $0 + $1.frameCount }
        guard totalFrames > 0 else { throw AudioMergeError.nothingToMerge }
        let chunk: AVAudioFrameCount = 1 << 16

        var sourceHash = SHA256()
        do {
            let output = try AVAudioFile(
                forWriting: destination,
                settings: writerSettings(for: format, container: container, totalFrames: totalFrames),
                commonFormat: processing.commonFormat, interleaved: true)
            defer { output.close() }
            var written: Int64 = 0
            for segment in segments {
                let input = inputs[segment.index]
                guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk) else {
                    throw AudioMergeError.incompatibleFormats(format.summary)
                }
                input.framePosition = segment.firstFrame
                let stop = segment.firstFrame + segment.frameCount
                while input.framePosition < stop {
                    if Task.isCancelled { throw AudioMergeError.cancelled }
                    try input.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(chunk), stop - input.framePosition)))
                    guard buffer.frameLength > 0 else { break }
                    update(&sourceHash, with: buffer)
                    try output.write(from: buffer)
                    written += Int64(buffer.frameLength)
                    // Writing is the first half of the work, verification the second.
                    progress(Double(written) / Double(max(totalFrames, 1)) * 0.6)
                }
            }
        }
        let expected = hex(sourceHash.finalize())

        // Read the archive back: same number of frames and identical samples, or it is not kept.
        let check = try AVAudioFile(forReading: destination, commonFormat: processing.commonFormat, interleaved: true)
        guard check.length == totalFrames,
              let buffer = AVAudioPCMBuffer(pcmFormat: check.processingFormat, frameCapacity: chunk) else {
            throw AudioMergeError.verificationFailed
        }
        var archiveHash = SHA256()
        while check.framePosition < check.length {
            if Task.isCancelled { throw AudioMergeError.cancelled }
            try check.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            update(&archiveHash, with: buffer)
            progress(0.6 + Double(check.framePosition) / Double(max(totalFrames, 1)) * 0.4)
        }
        guard hex(archiveHash.finalize()) == expected else { throw AudioMergeError.verificationFailed }

        Log.audio.info("Merged \(sources.count) files, \(totalFrames) frames, \(format.summary, privacy: .public) → \(container.rawValue, privacy: .public), verified")
        return MergedAudio(container: container, format: format, frameCount: totalFrames, pcmSHA256: expected)
    }

    private static func update(_ hash: inout SHA256, with buffer: AVAudioPCMBuffer) {
        let audio = buffer.audioBufferList.pointee.mBuffers
        guard let data = audio.mData else { return }
        let bytes = Int(buffer.frameLength) * Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        hash.update(bufferPointer: UnsafeRawBufferPointer(start: data, count: bytes))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 16 kHz / 16-bit FLAC rendition for uploading (see `ImportPipeline.uploadFile`).
    /// The archive itself is never altered. Blocking; call off the main actor.
    static func writeUploadProxy(from archive: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: archive)
        let source = input.processingFormat
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: source.channelCount, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 1 << 16),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 1 << 16) else {
            throw AudioMergeError.incompatibleFormats(source.description)
        }
        let output = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: Int(source.channelCount), AVEncoderBitDepthHintKey: 16,
        ])
        defer { output.close() }
        var readError: Error?
        while true {
            if Task.isCancelled { throw AudioMergeError.cancelled }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                inBuffer.frameLength = 0
                if input.framePosition < input.length {
                    do { try input.read(into: inBuffer) } catch { readError = error }
                }
                if readError != nil || inBuffer.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if let error = readError ?? conversionError { throw error }
            if outBuffer.frameLength > 0 { try output.write(from: outBuffer) }
            if status == .endOfStream || status == .error || outBuffer.frameLength == 0 { break }
        }
    }
}
