import XCTest
import AVFoundation
@testable import MicIngest

final class AudioMergerTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws { folder = try temporaryDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    /// Raw little-endian sample bytes of a WAV written by `writeWAV` (44-byte header).
    private func payload(_ url: URL) throws -> Data { try Data(contentsOf: url).dropFirst(44) }

    /// Decodes any audio file to interleaved little-endian samples: integers at the given width, or float32.
    private func decode(_ url: URL, bitDepth: Int, isFloat: Bool) throws -> Data {
        let file = try AVAudioFile(forReading: url, commonFormat: isFloat ? .pcmFormatFloat32 : .pcmFormatInt32, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        var data = Data()
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let count = Int(buffer.frameLength) * Int(file.processingFormat.channelCount)
            if isFloat {
                data.append(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: count))
            } else {
                for sample in UnsafeBufferPointer(start: buffer.int32ChannelData![0], count: count) {
                    var value = (sample >> (32 - bitDepth)).littleEndian
                    withUnsafeBytes(of: &value) { data.append(contentsOf: $0.prefix(bitDepth / 8)) }
                }
            }
        }
        return data
    }

    private func mergeAndCompare(bitDepth: Int, isFloat: Bool = false, channels: Int = 1,
                                 expecting container: ArchiveContainer) throws {
        let a = folder.appendingPathComponent("a.wav"), b = folder.appendingPathComponent("b.wav")
        try writeWAV(to: a, seconds: 3, sampleRate: 48_000, bitDepth: bitDepth, isFloat: isFloat, channels: channels)
        try writeWAV(to: b, seconds: 1.5, sampleRate: 48_000, bitDepth: bitDepth, isFloat: isFloat, channels: channels, frequency: 331)
        let before = try [a, b].map { try Data(contentsOf: $0) }
        let format = try AudioInspector.inspect(a).format
        XCTAssertEqual(format, AudioFormatInfo(sampleRate: 48_000, channels: channels, bitDepth: bitDepth, isFloat: isFloat))
        XCTAssertEqual(AudioMerger.container(for: format), container)

        let output = folder.appendingPathComponent("merged.\(container.fileExtension)")
        let merged = try AudioMerger.merge(sources: [a, b], format: format, to: output)
        XCTAssertEqual(merged.frameCount, Int64(4.5 * 48_000))

        // The archive reports the source's format…
        let archivedFile = try AVAudioFile(forReading: output)
        let archived = archivedFile.fileFormat.streamDescription.pointee
        XCTAssertEqual(archived.mSampleRate, 48_000)
        XCTAssertEqual(Int(archived.mChannelsPerFrame), channels)
        XCTAssertEqual(archived.mFormatID, container == .flac ? kAudioFormatFLAC : kAudioFormatLinearPCM)

        // …and decodes to exactly the concatenated source samples.
        let expected = try payload(a) + payload(b)
        XCTAssertEqual(try decode(output, bitDepth: bitDepth, isFloat: isFloat), expected)
        if container == .wav {
            XCTAssertEqual(Int(archived.mBitsPerChannel), bitDepth)
            XCTAssertEqual(archived.mFormatFlags & kAudioFormatFlagIsFloat != 0, isFloat)
        }
        // Sources are untouched.
        XCTAssertEqual(try [a, b].map { try Data(contentsOf: $0) }, before)
    }

    func test16BitIntegerBecomesBitExactFLAC() throws { try mergeAndCompare(bitDepth: 16, expecting: .flac) }
    func test24BitIntegerBecomesBitExactFLAC() throws { try mergeAndCompare(bitDepth: 24, expecting: .flac) }
    func test24BitStereoBecomesBitExactFLAC() throws { try mergeAndCompare(bitDepth: 24, channels: 2, expecting: .flac) }
    func test32BitFloatStaysFloatWAV() throws { try mergeAndCompare(bitDepth: 32, isFloat: true, expecting: .wav) }
    func test32BitIntegerStaysWAV() throws { try mergeAndCompare(bitDepth: 32, expecting: .wav) }

    func testFLACIsSmallerThanSource() throws {
        try mergeAndCompare(bitDepth: 24, expecting: .flac)
        let source = try payload(folder.appendingPathComponent("a.wav")).count + payload(folder.appendingPathComponent("b.wav")).count
        let archive = try Data(contentsOf: folder.appendingPathComponent("merged.flac")).count
        XCTAssertLessThan(archive, source)
    }

    func testIncompatibleChunksAreRefused() throws {
        let recordings = [
            recording("TX01_MIC001_20261001_100000_orig.wav", seconds: 1800),
            recording("TX01_MIC002_20261001_103000_orig.wav", seconds: 60,
                      format: AudioFormatInfo(sampleRate: 48_000, channels: 1, bitDepth: 32, isFloat: true)),
        ]
        XCTAssertThrowsError(try AudioMerger.commonFormat(of: recordings)) { error in
            guard case AudioMergeError.incompatibleFormats = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try AudioMerger.commonFormat(of: [recordings[0]]), testFormat)
    }

    func testUploadProxyIsSixteenKilohertzFLAC() throws {
        let a = folder.appendingPathComponent("a.wav")
        try writeWAV(to: a, seconds: 2, sampleRate: 48_000, bitDepth: 32, isFloat: true)
        let proxy = folder.appendingPathComponent("proxy.flac")
        try AudioMerger.writeUploadProxy(from: a, to: proxy)
        let file = try AVAudioFile(forReading: proxy)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(Double(file.length) / 16_000, 2, accuracy: 0.05)
    }
}

final class SessionPreviewTests: XCTestCase {
    func testChunksPlayBackToBackAsOneItem() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeWAV(to: folder.appendingPathComponent("TX01_MIC001_20261001_100000_orig.wav"), seconds: 8, sampleRate: 16_000)
        try writeWAV(to: folder.appendingPathComponent("TX01_MIC002_20261001_100008_orig.wav"), seconds: 5, sampleRate: 16_000)
        let scan = await SourceScanner.scan(folder, timeZone: berlin)
        let session = try XCTUnwrap(SessionGrouper(rolloverDuration: 8, rolloverSlack: 0.5).group(scan.recordings).first)
        XCTAssertEqual(session.recordings.count, 2)

        let (asset, chunks) = try await SessionPreview.composition(for: session)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 13, accuracy: 0.01, "one continuous clip")
        XCTAssertEqual(chunks.map(\.offsetSeconds), [0, 8])
        XCTAssertEqual(chunks.map(\.start), session.recordings.map(\.start))
        XCTAssertEqual(SessionPreview.offset(of: session.recordings[1], in: session), 8, accuracy: 0.001)
        // Clock time continues across the file boundary.
        let timeline = SessionTimeline(chunks: chunks, timeZone: berlin)
        XCTAssertEqual(timeline.clockTime(atMs: 9_000), "10:00:09")
    }
}

final class TrimTests: XCTestCase {
    func testMergePlan() {
        // Three files of 100, 50 and 80 frames.
        let counts: [Int64] = [100, 50, 80]
        XCTAssertEqual(MergePlan.segments(frameCounts: counts, keeping: nil), [
            MergeSegment(index: 0, firstFrame: 0, frameCount: 100, outputOffset: 0),
            MergeSegment(index: 1, firstFrame: 0, frameCount: 50, outputOffset: 100),
            MergeSegment(index: 2, firstFrame: 0, frameCount: 80, outputOffset: 150),
        ])
        // Trimmed inside the first and the last file.
        XCTAssertEqual(MergePlan.segments(frameCounts: counts, keeping: 30..<200), [
            MergeSegment(index: 0, firstFrame: 30, frameCount: 70, outputOffset: 0),
            MergeSegment(index: 1, firstFrame: 0, frameCount: 50, outputOffset: 70),
            MergeSegment(index: 2, firstFrame: 0, frameCount: 50, outputOffset: 120),
        ])
        // Whole files outside the range are left out.
        XCTAssertEqual(MergePlan.segments(frameCounts: counts, keeping: 110..<140), [
            MergeSegment(index: 1, firstFrame: 10, frameCount: 30, outputOffset: 0),
        ])
    }

    func testTrimFramesAreSampleExactAndClamped() {
        XCTAssertEqual(Trim(start: 1.5, end: 3.25).frames(sampleRate: 48_000, totalFrames: 1_000_000), 72_000..<156_000)
        XCTAssertEqual(Trim(start: -1, end: 99).frames(sampleRate: 1000, totalFrames: 5000), 0..<5000)
    }

    func testTrimmedMergeIsBitExactAcrossAFileBoundary() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.wav"), b = folder.appendingPathComponent("b.wav")
        try writeWAV(to: a, seconds: 4, sampleRate: 8000, bitDepth: 24)
        try writeWAV(to: b, seconds: 3, sampleRate: 8000, bitDepth: 24, frequency: 330)
        let format = try AudioInspector.inspect(a).format
        // Keep from 2.5 s into a.wav to 1 s into b.wav.
        let range = Trim(start: 2.5, end: 5).frames(sampleRate: 8000, totalFrames: 7 * 8000)
        let output = folder.appendingPathComponent("trimmed.flac")
        let merged = try AudioMerger.merge(sources: [a, b], format: format, to: output, keeping: range)
        XCTAssertEqual(merged.frameCount, 20_000)

        let payload = { (url: URL) in try Data(contentsOf: url).dropFirst(44) }
        let expected = Data(try payload(a).dropFirst(20_000 * 3)) + Data(try payload(b).prefix(8000 * 3))
        let file = try AVAudioFile(forReading: output, commonFormat: .pcmFormatInt32, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        var decoded = Data()
        while file.framePosition < file.length {
            try file.read(into: buffer)
            for sample in UnsafeBufferPointer(start: buffer.int32ChannelData![0], count: Int(buffer.frameLength)) {
                var value = (sample >> 8).littleEndian
                withUnsafeBytes(of: &value) { decoded.append(contentsOf: $0.prefix(3)) }
            }
        }
        XCTAssertEqual(decoded, expected)
    }

    @MainActor
    func testSettingTrimKeepsItSensibleAndPersists() async throws {
        let database = try AppDatabase.inMemory()
        let session = try XCTUnwrap(SessionGrouper().group(Array(briefRecordings()[1...5])).first)   // 7,697.6 s
        let source = SourceModel(database: database, settings: AppSettings(defaults: UserDefaults(suiteName: "trim-\(UUID())")!))

        source.setTrim(start: 120, for: session)
        XCTAssertEqual(source.trim(for: session), Trim(start: 120, end: session.duration))
        source.setTrim(end: 7000, for: session)
        XCTAssertEqual(source.trim(for: session), Trim(start: 120, end: 7000))
        source.setTrim(start: 7500, for: session)   // past the end: the end moves back out
        XCTAssertEqual(source.trim(for: session), Trim(start: 7500, end: session.duration))
        source.setTrim(end: 7000, for: session)     // before the start: at least a second is kept
        XCTAssertEqual(source.trim(for: session), Trim(start: 7500, end: 7501))
        XCTAssertEqual(try database.trims()[session.fingerprint], Trim(start: 7500, end: 7501))

        source.setTrim(start: 0, end: session.duration, for: session)
        XCTAssertNil(source.trim(for: session), "keeping everything is no trim")
        source.setTrim(start: 60, for: session)
        source.resetTrim(for: session)
        XCTAssertNil(source.trim(for: session))
        XCTAssertTrue(try database.trims().isEmpty)

        // Clock times of a trimmed session follow the files' own timestamps.
        let trim = Trim(start: 1800.6 + 60, end: 1800.6 + 1800 + 30)   // 1 min into MIC003 … 30 s into MIC004
        XCTAssertEqual(session.start(trimmedBy: trim), date("2026-10-01 21:14:50"))
        XCTAssertEqual(session.end(trimmedBy: trim), date("2026-10-01 21:44:20"))
    }
}
