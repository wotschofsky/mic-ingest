import XCTest
@testable import MicIngest

final class DJIFilenameTests: XCTestCase {
    func testParsesStandardName() throws {
        let parsed = try XCTUnwrap(DJIFilename("TX01_MIC002_20261001_204349_orig.wav"))
        XCTAssertEqual(parsed.transmitter, "TX01")
        XCTAssertEqual(parsed.sequence, 2)
        XCTAssertEqual(parsed.variant, "orig")
        XCTAssertEqual(parsed.startDate(in: berlin), date("2026-10-01 20:43:49"))
    }

    func testIsNotTiedToDigitCountsOrSuffix() throws {
        XCTAssertEqual(DJIFilename("TX2_MIC1234_20261001_204349.WAV")?.sequence, 1234)
        XCTAssertEqual(DJIFilename("TX2_MIC1234_20261001_204349.WAV")?.transmitter, "TX2")
        XCTAssertEqual(DJIFilename("tx01_mic7_20261001_204349_orig.wav")?.transmitter, "TX01")
        XCTAssertEqual(DJIFilename("TX01_MIC002_20261001_204349_orig_32bit.wav")?.variant, "orig_32bit")
    }

    func testRejectsMalformedAndForeignFiles() {
        for name in ["", "notes.txt", "TX01_MIC002_20261001_204349_orig.mp3", "._TX01_MIC002_20261001_204349_orig.wav",
                     "TX01_MIC002_20261301_204349_orig.wav", "TX01_MIC002_20261001_254349_orig.wav",
                     "TX01_MIC002_20260230_204349_orig.wav", "TX01_MIC_20261001_204349_orig.wav",
                     "TX01_MIC002_2026101_204349_orig.wav", "DJI_0001.wav", "TX01_MIC002_20261001_204349_orig.wav.tmp"] {
            XCTAssertNil(DJIFilename(name), name)
        }
    }

    func testSpringForwardGapIsNotTreatedAsMalformed() {
        // 02:30 does not exist in Berlin on 29 March 2026; the recorder may still write it.
        XCTAssertNotNil(DJIFilename("TX01_MIC002_20260329_023000_orig.wav")?.startDate(in: berlin))
    }
}

final class SessionGroupingTests: XCTestCase {
    let grouper = SessionGrouper()

    private func names(_ sessions: [RecordingSession]) -> [[Int]] {
        sessions.map { $0.recordings.map(\.sequence) }
    }

    func testBriefExampleProducesExpectedSessions() {
        let sessions = grouper.group(briefRecordings().shuffled())
        XCTAssertEqual(names(sessions), [[1], [2, 3, 4, 5, 6], [7], [8], [9], [10, 11]])
    }

    func testThirtyMinuteRolloversAreOneSession() {
        let sessions = grouper.group(Array(briefRecordings()[1...5]))
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].start, date("2026-10-01 20:43:49"))
        XCTAssertEqual(sessions[0].duration, 1800.6 + 1800 * 3 + 497, accuracy: 0.001)
        XCTAssertEqual(sessions[0].members.map(\.decision),
                       [.first, .automaticRollover, .automaticRollover, .automaticRollover, .automaticRollover])
    }

    func testRolloverAcrossMidnightIsOneSession() {
        let sessions = grouper.group(Array(briefRecordings()[9...10]))
        XCTAssertEqual(names(sessions), [[10, 11]])
        XCTAssertEqual(sessions[0].end, date("2026-10-02 00:28:07"))
    }

    func testShortRecordingsCloseTogetherStaySeparate() {
        let sessions = grouper.group(Array(briefRecordings()[6...8]))
        XCTAssertEqual(names(sessions), [[7], [8], [9]])
    }

    func testImmediateRestartIsSeparateButFlaggedAsPossibleContinuation() {
        // 9.4 s recording, next one starts 10 s after it began: contiguous, but not a 30-minute rollover.
        let sessions = grouper.group(Array(briefRecordings()[6...7]))
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(sessions[1].looksLikeContinuation)
        XCTAssertFalse(sessions[0].looksLikeContinuation)
    }

    func testGapBeyondToleranceSeparatesEvenAfterFullLengthFile() {
        let sessions = grouper.group([
            recording("TX01_MIC001_20261001_100000_orig.wav", seconds: 1800),
            recording("TX01_MIC002_20261001_103003_orig.wav", seconds: 1800), // 3 s late
            recording("TX01_MIC003_20261001_105957_orig.wav", seconds: 600),  // 6 s early
        ])
        XCTAssertEqual(names(sessions), [[1], [2], [3]])
        XCTAssertEqual(sessions[1].members[0].decision, .gap)
    }

    func testImperfectTimingInsideToleranceIsSameSession() {
        let sessions = grouper.group([
            recording("TX01_MIC001_20261001_100000_orig.wav", seconds: 1800),
            recording("TX01_MIC002_20261001_103002_orig.wav", seconds: 1800), // 2 s late
            recording("TX01_MIC003_20261001_110000_orig.wav", seconds: 1799), // 2 s early
            recording("TX01_MIC004_20261001_112959_orig.wav", seconds: 60),   // exactly on time
        ])
        XCTAssertEqual(names(sessions), [[1, 2, 3, 4]])
    }

    func testDifferentTransmittersNeverMerge() {
        let sessions = grouper.group([
            recording("TX01_MIC001_20261001_100000_orig.wav", seconds: 1800),
            recording("TX02_MIC002_20261001_103000_orig.wav", seconds: 1800),
            recording("TX01_MIC002_20261001_103000_orig.wav", seconds: 300),
        ])
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions.map(\.transmitter)), ["TX01", "TX02"])
        XCTAssertEqual(sessions.first { $0.transmitter == "TX01" }?.recordings.count, 2)
    }

    func testDifferentRenditionsOfTheSameTakeDoNotMerge() {
        let sessions = grouper.group([
            recording("TX01_MIC001_20261001_100000_orig.wav", seconds: 1800),
            recording("TX01_MIC001_20261001_100000_nc.wav", seconds: 1800),
            recording("TX01_MIC002_20261001_103000_orig.wav", seconds: 300),
        ])
        XCTAssertEqual(sessions.count, 2)
    }

    func testEmptyAndSingleInput() {
        XCTAssertTrue(grouper.group([]).isEmpty)
        XCTAssertEqual(grouper.group([briefRecordings()[0]]).count, 1)
    }

    func testManualSplitAndMergeOverrideAutomaticDecisions() {
        let all = briefRecordings()
        let overrides: [String: BoundaryOverride] = [
            all[3].fingerprint: .split,  // split the long session in front of MIC004
            all[7].fingerprint: .merge,  // merge MIC008 into MIC007
        ]
        let sessions = grouper.group(all, overrides: overrides)
        XCTAssertEqual(names(sessions), [[1], [2, 3], [4, 5, 6], [7, 8], [9], [10, 11]])
    }

    func testFingerprintIsStableAndChangesWithGrouping() {
        let all = briefRecordings()
        let first = grouper.group(all)[1]
        let again = grouper.group(all.reversed())[1]
        XCTAssertEqual(first.fingerprint, again.fingerprint)
        let split = grouper.group(all, overrides: [all[3].fingerprint: .split])[1]
        XCTAssertNotEqual(first.fingerprint, split.fingerprint)
    }
}

final class SourceScannerTests: XCTestCase {
    func testScanReadsRealDurationsAndIgnoresForeignFiles() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeWAV(to: folder.appendingPathComponent("TX01_MIC001_20261001_193402_orig.wav"), seconds: 2.5)
        let nested = folder.appendingPathComponent("DJI_Audio")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeWAV(to: nested.appendingPathComponent("TX01_MIC002_20261001_204349_orig.wav"), seconds: 1, bitDepth: 24)
        try writeWAV(to: folder.appendingPathComponent("holiday.wav"), seconds: 1)
        try Data("not audio".utf8).write(to: folder.appendingPathComponent("TX01_MIC003_20261001_211350_orig.wav"))
        try Data().write(to: folder.appendingPathComponent("readme.txt"))

        let scan = await SourceScanner.scan(folder, timeZone: berlin)
        let recordings = scan.recordings.sorted { $0.sequence < $1.sequence }
        XCTAssertEqual(recordings.map(\.sequence), [1, 2])
        XCTAssertEqual(recordings[0].duration, 2.5, accuracy: 0.0001)
        XCTAssertEqual(recordings[0].format, AudioFormatInfo(sampleRate: 8000, channels: 1, bitDepth: 16, isFloat: false))
        XCTAssertEqual(recordings[1].format.bitDepth, 24)
        XCTAssertEqual(scan.problems.map(\.filename), ["TX01_MIC003_20261001_211350_orig.wav"])
    }
}
