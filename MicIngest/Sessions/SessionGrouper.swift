import Foundation
import CryptoKit

/// Why a recording was (or was not) joined to the one before it.
enum BoundaryDecision: Equatable {
    /// First recording of its transmitter.
    case first
    /// Previous file hit the recorder's maximum length and this one starts where it ended.
    case automaticRollover
    /// Starts where the previous one ended, but the previous one was not at maximum length:
    /// more likely a manual stop and restart. Kept separate, offered as an easy merge.
    case contiguousButNotRollover
    /// Starts somewhere other than where the previous recording ended.
    case gap
    case manualMerge
    case manualSplit

    var joinsPrevious: Bool { self == .automaticRollover || self == .manualMerge }
}

/// User correction for the boundary in front of one recording, keyed by that recording's fingerprint.
enum BoundaryOverride: String, Codable {
    case merge, split
}

struct SessionMember: Hashable {
    var recording: SourceRecording
    var decision: BoundaryDecision
}

/// One real-world recording session: the unit the user sees, selects and imports.
struct RecordingSession: Identifiable, Hashable {
    var members: [SessionMember]

    var recordings: [SourceRecording] { members.map(\.recording) }
    var transmitter: String { members[0].recording.transmitter }
    var start: Date { members[0].recording.start }
    /// Sum of the actual audio durations (what the merged file will contain).
    var duration: TimeInterval { members.reduce(0) { $0 + $1.recording.duration } }
    var end: Date { members[members.count - 1].recording.end }

    /// Stable across rescans and regrouping-neutral changes: derived from the source material itself.
    var fingerprint: String {
        let joined = recordings.map(\.fingerprint).joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var id: String { fingerprint }

    /// True when this session directly follows the previous one in time and could plausibly belong to it.
    var looksLikeContinuation: Bool { members[0].decision == .contiguousButNotRollover }
}

struct SessionGrouper {
    var rolloverDuration = AppConfig.Grouping.rolloverDuration
    var rolloverSlack = AppConfig.Grouping.rolloverSlack
    var timingTolerance = AppConfig.Grouping.timingTolerance

    /// Automatic decision for `next` given the recording before it on the same transmitter.
    func decision(previous: SourceRecording, next: SourceRecording) -> BoundaryDecision {
        let expectedStart = previous.start.addingTimeInterval(previous.duration)
        let offBy = abs(next.start.timeIntervalSince(expectedStart))
        guard offBy <= timingTolerance else { return .gap }
        let previousHitMaximum = previous.duration >= rolloverDuration - rolloverSlack
        return previousHitMaximum ? .automaticRollover : .contiguousButNotRollover
    }

    func group(_ recordings: [SourceRecording], overrides: [String: BoundaryOverride] = [:]) -> [RecordingSession] {
        // Each transmitter (and file rendition) is its own timeline; recordings never merge across them.
        let streams = Dictionary(grouping: recordings) { "\($0.transmitter)|\($0.variant)" }
        var sessions: [RecordingSession] = []

        for stream in streams.values {
            let ordered = stream.sorted { ($0.start, $0.sequence, $0.filename) < ($1.start, $1.sequence, $1.filename) }
            var current: [SessionMember] = []
            for (index, recording) in ordered.enumerated() {
                var decision: BoundaryDecision = index == 0 ? .first : self.decision(previous: ordered[index - 1], next: recording)
                if index > 0 {
                    switch overrides[recording.fingerprint] {
                    case .merge: decision = .manualMerge
                    case .split: decision = .manualSplit
                    case nil: break
                    }
                    Log.grouping.debug("\(recording.filename, privacy: .public): \(String(describing: decision), privacy: .public)")
                }
                if !decision.joinsPrevious, !current.isEmpty {
                    sessions.append(RecordingSession(members: current))
                    current = []
                }
                current.append(SessionMember(recording: recording, decision: decision))
            }
            if !current.isEmpty { sessions.append(RecordingSession(members: current)) }
        }
        return sessions.sorted { ($0.start, $0.transmitter) < ($1.start, $1.transmitter) }
    }
}
