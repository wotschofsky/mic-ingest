import Foundation

/// The part of a session to keep, in seconds from the session's first sample. Only the ends can be
/// trimmed; nothing in between is cut.
struct Trim: Codable, Hashable {
    var start: Double
    var end: Double

    var duration: Double { end - start }

    /// Sample-exact frame range over the session's concatenated audio.
    func frames(sampleRate: Double, totalFrames: Int64) -> Range<Int64> {
        let first = min(max(0, Int64((start * sampleRate).rounded())), totalFrames)
        let last = min(max(first, Int64((end * sampleRate).rounded())), totalFrames)
        return first..<last
    }
}

/// One source file's share of a merge: which of its frames are used and where they land.
struct MergeSegment: Equatable {
    var index: Int
    /// First frame used, within the source file.
    var firstFrame: Int64
    var frameCount: Int64
    /// Where these frames start in the merged audio.
    var outputOffset: Int64
}

enum MergePlan {
    /// The files (or parts of files) that make up `range` of the concatenated audio; all of every
    /// file when `range` is nil. Files entirely outside the range are left out.
    static func segments(frameCounts: [Int64], keeping range: Range<Int64>?) -> [MergeSegment] {
        let total = frameCounts.reduce(0, +)
        let keep = range ?? 0..<total
        var segments: [MergeSegment] = []
        var position: Int64 = 0
        for (index, count) in frameCounts.enumerated() {
            defer { position += count }
            let from = max(position, keep.lowerBound), to = min(position + count, keep.upperBound)
            guard from < to else { continue }
            segments.append(MergeSegment(index: index, firstFrame: from - position, frameCount: to - from,
                                         outputOffset: from - keep.lowerBound))
        }
        return segments
    }
}

extension RecordingSession {
    /// Positions in the session (seconds from its first sample) to clock times, per source file.
    var timeline: SessionTimeline {
        var offset = 0.0
        return SessionTimeline(chunks: recordings.map { recording in
            defer { offset += recording.duration }
            return .init(offsetSeconds: offset, start: recording.start)
        }, timeZone: .current)
    }

    func start(trimmedBy trim: Trim?) -> Date {
        trim.map { timeline.date(atMs: Int(($0.start * 1000).rounded())) } ?? start
    }

    func end(trimmedBy trim: Trim?) -> Date {
        trim.map { timeline.date(atMs: Int(($0.end * 1000).rounded())) } ?? end
    }
}
