import AVFoundation
import Observation

/// Plays a session straight from the recorder before it is imported: its chunks are laid end to end
/// in a composition, so they sound and scrub like one recording. Nothing is merged or copied, and
/// the source files are only read.
@MainActor
@Observable
final class SessionPreview {
    private(set) var session: RecordingSession?
    private(set) var error: String?
    let player = PlayerModel()
    private var timeline = SessionTimeline(chunks: [], timeZone: .current)
    private var loading: Task<Void, Never>?

    /// Starts `session` at `offset` seconds, or toggles playback if it is already loaded.
    func play(_ session: RecordingSession, at offset: Double? = nil) {
        if self.session?.id == session.id, player.isAvailable {
            if let offset { player.seek(to: offset, play: true) } else { player.togglePlayback() }
            return
        }
        stop()
        self.session = session
        loading = Task {
            do {
                let (asset, chunks) = try await Self.composition(for: session)
                guard !Task.isCancelled else { return }
                timeline = SessionTimeline(chunks: chunks, timeZone: .current)
                player.load(AVPlayerItem(asset: asset), duration: session.duration)
                player.seek(to: offset ?? 0, play: true)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Could not play this recording: \(error.localizedDescription)"
                Log.audio.error("Preview failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func isPlaying(_ session: RecordingSession) -> Bool { self.session?.id == session.id && player.isPlaying }

    func stop() {
        loading?.cancel()
        player.unload()
        session = nil
        error = nil
    }

    func clock(atSeconds seconds: Double) -> String { timeline.clockTime(atMs: Int(seconds * 1000)) }

    /// Seconds into the session at which `recording` starts.
    nonisolated static func offset(of recording: SourceRecording, in session: RecordingSession) -> Double {
        session.recordings.prefix { $0 != recording }.reduce(0) { $0 + $1.duration }
    }

    /// The session's chunks back to back, with each chunk's start for the clock display.
    nonisolated static func composition(for session: RecordingSession) async throws -> (AVAsset, [SessionTimeline.Chunk]) {
        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        var chunks: [SessionTimeline.Chunk] = []
        for recording in session.recordings {
            let asset = AVURLAsset(url: recording.url)
            let duration = try await asset.load(.duration)
            try await composition.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: asset, at: cursor)
            chunks.append(.init(offsetSeconds: cursor.seconds, start: recording.start))
            cursor = CMTimeAdd(cursor, duration)
        }
        return (composition, chunks)
    }
}
