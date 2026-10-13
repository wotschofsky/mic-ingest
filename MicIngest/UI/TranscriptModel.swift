import AVFoundation
import Observation

/// Audio playback (a transcript's archive, or a session preview): play/pause, seek, current time.
@MainActor
@Observable
final class PlayerModel {
    private(set) var isPlaying = false
    private(set) var currentSeconds = 0.0
    private(set) var durationSeconds = 0.0
    private(set) var isAvailable = false

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var rateObservation: NSKeyValueObservation?
    /// Where the latest seek is going. Until it lands, the player still reports the old position;
    /// showing that would make the scrubber jump back for a moment.
    private var seekTarget: Double?

    func load(_ url: URL?, duration: Double) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            unload()
            durationSeconds = duration
            return
        }
        load(AVPlayerItem(url: url), duration: duration)
    }

    func load(_ item: AVPlayerItem, duration: Double) {
        unload()
        durationSeconds = duration
        let player = AVPlayer(playerItem: item)
        self.player = player
        isAvailable = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.seekTarget == nil else { return }
                self.currentSeconds = time.seconds
            }
        }
        rateObservation = player.observe(\.rate) { [weak self] player, _ in
            Task { @MainActor in self?.isPlaying = player.rate != 0 }
        }
    }

    func unload() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        rateObservation = nil
        player?.pause()
        player = nil
        seekTarget = nil
        isAvailable = false
        isPlaying = false
        currentSeconds = 0
    }

    func togglePlayback() {
        guard let player else { return }
        if player.rate != 0 { player.pause() } else { player.play() }
    }

    func seek(to seconds: Double, play: Bool = false) {
        guard let player else { return }
        currentSeconds = seconds
        seekTarget = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            // A seek replaced by a newer one also completes (unfinished); only the latest one clears the target.
            Task { @MainActor in
                guard let self, self.seekTarget == seconds else { return }
                self.seekTarget = nil
            }
        }
        if play { player.play() }
    }
}

/// One row of the transcript viewer, precomputed so scrolling stays cheap for multi-hour recordings.
struct TranscriptRow: Identifiable, Equatable {
    var id: Int
    var speaker: String
    var startMs: Int
    var endMs: Int
    var clock: String
    var text: String
}

/// A transcript opened in the viewer: rows, speaker identities, playback and manual identity edits.
@MainActor
@Observable
final class TranscriptModel {
    let sessionID: String
    private(set) var session: ImportedSession?
    private(set) var metadata: SessionMetadata?
    private(set) var rows: [TranscriptRow] = []
    private(set) var loadError: String?
    private(set) var isLoading = true
    private(set) var isUpdatingSpeaker = false
    private(set) var isReanalyzing = false
    private(set) var actionError: String?
    let player = PlayerModel()

    private var transcript: Transcript?
    private let database: AppDatabase
    private let identity: IdentityService
    private let pipeline: ImportPipeline
    private var store: SessionStore { SessionStore(database: database) }

    init(sessionID: String, database: AppDatabase, identity: IdentityService, pipeline: ImportPipeline) {
        self.sessionID = sessionID
        self.database = database
        self.identity = identity
        self.pipeline = pipeline
    }

    var files: SessionFiles? { session.map(store.files) }
    var speakers: [SpeakerEntry] { metadata?.speakers ?? [] }
    var warnings: [String] { metadata?.processing.warnings ?? [] }
    func speaker(_ label: String) -> SpeakerEntry? { metadata?.speakers.first { $0.label == label } }

    /// Index of the row being spoken at the player's current position.
    var currentRowID: Int? {
        guard player.isAvailable, player.currentSeconds > 0 || player.isPlaying else { return nil }
        let ms = Int(player.currentSeconds * 1000)
        // Rows are ordered by start time: binary search for the last one that has started.
        var low = 0, high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid].startMs <= ms { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? rows[low - 1].id : nil
    }

    func clock(atSeconds seconds: Double) -> String {
        metadata?.timeline.clockTime(atMs: Int(seconds * 1000)) ?? ""
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let session = try database.session(id: sessionID) else { return }
            self.session = session
            let store = store
            // Decoding a multi-hour response is the slow part; keep it off the main actor.
            let (metadata, transcript, rows) = try await Task.detached(priority: .userInitiated) {
                let metadata = try store.metadata(for: session)
                let transcript = try store.transcript(for: session)
                let timeline = metadata.timeline
                let rows = transcript.utterances.map {
                    TranscriptRow(id: $0.index, speaker: $0.speaker, startMs: $0.startMs, endMs: $0.endMs,
                                  clock: timeline.clockTime(atMs: $0.startMs), text: $0.text)
                }
                return (metadata, transcript, rows)
            }.value
            self.metadata = metadata
            self.transcript = transcript
            self.rows = rows
            loadError = nil
            player.load(store.audioURL(for: session), duration: metadata.session.durationSeconds)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Picks up speaker names changed elsewhere (a person renamed or deleted in Settings).
    func refreshMetadata() {
        guard let current = try? database.session(id: sessionID), let metadata = try? store.metadata(for: current) else { return }
        session = current
        self.metadata = metadata
    }

    func play(_ row: TranscriptRow) {
        player.seek(to: Double(row.startMs) / 1000, play: true)
    }

    /// Applies a manual identity decision, then rewrites metadata and Markdown. No retranscription.
    func setIdentity(_ decision: ManualDecision?, for label: String) async {
        guard var session, let metadata, let transcript else { return }
        isUpdatingSpeaker = true
        defer { isUpdatingSpeaker = false }
        let updated = await identity.apply(decision, to: label, transcript: transcript, metadata: metadata, audio: store.audioURL(for: session))
        do {
            try store.save(updated, for: &session)
            try store.writeMarkdown(transcript: transcript, metadata: updated, for: session)
            self.session = session
            self.metadata = updated
            actionError = nil
        } catch {
            actionError = "Could not save the change: \(error.localizedDescription)"
        }
    }

    /// Retries only the speaker analysis (voice + Groq); the transcription is reused.
    func reanalyzeSpeakers() async {
        isReanalyzing = true
        defer { isReanalyzing = false }
        do {
            try await pipeline.reanalyze(sessionID: sessionID)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
        await load()
    }
}
