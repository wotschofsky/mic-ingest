import AppKit
import Observation

/// State of the import screen's source side: where recordings come from and how they are grouped.
@MainActor
@Observable
final class SourceModel {
    /// Where recordings are read from: every connected recorder volume, or one folder the user chose.
    private(set) var folders: [URL] = []
    /// True when `folders` are auto-detected recorder volumes rather than a manually chosen folder.
    private(set) var isShowingRecorders = false
    private(set) var isScanning = false
    private(set) var problems: [SourceProblem] = []
    private(set) var sessions: [RecordingSession] = []
    /// Source chunk fingerprint → ID of the session it was imported with.
    private(set) var importedSources: [String: String] = [:]
    /// Selection is tracked per chunk so it survives splitting and merging sessions.
    private var selectedRecordings: Set<String> = []

    private var recordings: [SourceRecording] = []
    private var overrides: [String: BoundaryOverride] = [:]
    /// Trimmed ends by session fingerprint. Kept across rescans; a session regrouped by split or
    /// merge has a new fingerprint and starts untrimmed.
    private(set) var trims: [String: Trim] = [:]
    private let database: AppDatabase
    private let settings: AppSettings
    private let grouper = SessionGrouper()
    private var scanTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// Sessions shorter than this start out unselected (pocket recordings, tests). Everything longer that
    /// is not imported yet starts selected, including old recordings still on the recorder; the Import
    /// button always shows the count, and Select None is one click.
    static let autoSelectMinimumDuration: TimeInterval = 120
    /// Sessions shorter than this are button-press fragments; the list tucks them away by default.
    static let fragmentDuration: TimeInterval = 10

    init(database: AppDatabase, settings: AppSettings) {
        self.database = database
        self.settings = settings
        overrides = (try? database.boundaryOverrides()) ?? [:]
        trims = (try? database.trims()) ?? [:]
    }

    // MARK: Trimming

    func trim(for session: RecordingSession) -> Trim? { trims[session.fingerprint] }

    /// Sets where the import starts or ends (seconds into the session). At least a second is always kept;
    /// a trim that keeps everything is the same as none.
    func setTrim(start: Double? = nil, end: Double? = nil, for session: RecordingSession) {
        let current = trims[session.fingerprint] ?? Trim(start: 0, end: session.duration)
        var trim = Trim(start: start ?? current.start, end: end ?? current.end)
        trim.start = min(max(0, trim.start), session.duration - 1)
        trim.end = min(max(trim.end, trim.start + 1), session.duration)
        if start != nil, trim.end <= trim.start + 1 { trim.end = session.duration }
        let keepsEverything = trim.start < 0.5 && trim.end > session.duration - 0.5
        trims[session.fingerprint] = keepsEverything ? nil : trim
        try? database.setTrim(trims[session.fingerprint], for: session.fingerprint)
    }

    func resetTrim(for session: RecordingSession) {
        trims[session.fingerprint] = nil
        try? database.setTrim(nil, for: session.fingerprint)
    }

    var hasSource: Bool { !folders.isEmpty }
    var recordingCount: Int { recordings.count }
    var transmitters: [String] { Set(recordings.map(\.transmitter)).sorted() }
    /// Which microphone's recordings are on screen. Each transmitter is its own tab, since two
    /// microphones from one case are often worn by different people.
    var transmitterTab: String?
    var visibleTransmitter: String? {
        transmitterTab.flatMap { transmitters.contains($0) ? $0 : nil } ?? transmitters.first
    }
    var visibleSessions: [RecordingSession] { sessions.filter { $0.transmitter == visibleTransmitter } }
    /// Only the visible microphone's tab: Import acts on what is on screen. Selections on the other
    /// tab are kept but imported only from that tab.
    var selectedSessions: [RecordingSession] { visibleSessions.filter(isSelected) }

    /// One line describing the source: the connected transmitters, or the chosen folder.
    var sourceDescription: String {
        guard hasSource else { return "" }
        if isShowingRecorders {
            let names = transmitters.isEmpty ? "Recorder connected" : transmitters.joined(separator: ", ")
            return "\(names) · \(recordings.count) recordings" + clockNote
        }
        return Format.path(folders[0]) + clockNote
    }

    /// Shown whenever recorder timestamps are being converted, so shifted times are never a mystery.
    private var clockNote: String {
        guard let zone = settings.recorderTimeZone, zone.secondsFromGMT() != TimeZone.current.secondsFromGMT() else { return "" }
        return " · recorder clock \(Format.utcOffset(zone))"
    }

    // MARK: Discovery

    /// Opens the best source available now and watches for recorder volumes being mounted and unmounted.
    /// A fixed `initialFolder` (debug builds) turns automatic detection off.
    /// Scanning arbitrary mounted volumes without the user picking them first is only possible because
    /// the app is not sandboxed; that is the reason it isn't (hardened runtime is on).
    func start(initialFolder: URL? = nil) {
        if let initialFolder { return show([initialFolder], recorders: false) }

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in await self?.volumeMounted(url) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in self?.volumeUnmounted(url) }
        })
        Task {
            let volumes = await Self.volumesWithRecordings()
            if !volumes.isEmpty {
                show(volumes, recorders: true)
            } else if let remembered = settings.sourceFolder, FileManager.default.fileExists(atPath: remembered.path) {
                show([remembered], recorders: false)
            }
        }
    }

    /// External volumes that contain DJI recordings. The volume name does not matter (a charging case
    /// mounts each transmitter as its own, identically named volume); the recordings do.
    private static func volumesWithRecordings() async -> [URL] {
        await Task.detached {
            let keys: [URLResourceKey] = [.volumeIsInternalKey]
            let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: .skipHiddenVolumes) ?? []
            return volumes.filter { url in
                (try? url.resourceValues(forKeys: Set(keys)))?.volumeIsInternal != true && SourceScanner.containsRecordings(url)
            }
        }.value
    }

    private func volumeMounted(_ url: URL) async {
        let found = await Task.detached { SourceScanner.containsRecordings(url) }.value
        Log.source.info("Volume mounted, DJI recordings found: \(found)")
        guard found, !folders.contains(url) else { return }
        // A second transmitter joins the first; a recorder replaces a manually chosen folder.
        show(isShowingRecorders ? folders + [url] : [url], recorders: true)
    }

    private func volumeUnmounted(_ url: URL) {
        guard folders.contains(where: { $0.path == url.path || $0.path.hasPrefix(url.path + "/") }) else { return }
        let remaining = folders.filter { !($0.path == url.path || $0.path.hasPrefix(url.path + "/")) }
        if remaining.isEmpty { close() } else { show(remaining, recorders: isShowingRecorders) }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder that contains the DJI recordings. Nothing in it will be changed."
        if panel.runModal() == .OK, let url = panel.url {
            settings.sourceFolder = url
            show([url], recorders: false)
        }
    }

    private func show(_ urls: [URL], recorders: Bool) {
        // Keep what is already on screen when a second recorder is added; start fresh otherwise.
        let extending = recorders && isShowingRecorders && Set(folders).isSubset(of: Set(urls))
        folders = urls
        isShowingRecorders = recorders
        if !extending {
            selectedRecordings = []
            recordings = []
            sessions = []
        }
        rescan(resetSelection: true)
    }

    func close() {
        scanTask?.cancel()
        folders = []
        isShowingRecorders = false
        recordings = []
        problems = []
        sessions = []
        isScanning = false
    }

    func rescan(resetSelection: Bool = false) {
        guard hasSource else { return }
        let folders = folders
        let recorderZone = settings.recorderTimeZone ?? .current
        scanTask?.cancel()
        isScanning = true
        scanTask = Task {
            var scan = SourceScan()
            for folder in folders {
                let scoped = folder.startAccessingSecurityScopedResource()
                let part = await SourceScanner.scan(folder, timeZone: recorderZone)
                if scoped { folder.stopAccessingSecurityScopedResource() }
                scan.recordings += part.recordings
                scan.problems += part.problems
            }
            guard !Task.isCancelled else { return }
            recordings = scan.recordings
            problems = scan.problems
            isScanning = false
            regroup()
            if resetSelection { selectDefaults() }
        }
    }

    // MARK: Grouping

    private func regroup() {
        sessions = grouper.group(recordings, overrides: overrides)
        refreshImported()
    }

    func refreshImported() {
        importedSources = (try? database.importedSources()) ?? [:]
    }

    private func setOverride(_ kind: BoundaryOverride?, for recording: SourceRecording) {
        overrides[recording.fingerprint] = kind
        try? database.setBoundaryOverride(kind, for: recording.fingerprint)
        regroup()
    }

    /// The session directly before `session` on the same recorder timeline, if any.
    func previous(of session: RecordingSession) -> RecordingSession? {
        let first = session.recordings[0]
        return sessions.last { $0.transmitter == first.transmitter && $0.recordings[0].variant == first.variant && $0.start < session.start }
    }

    func mergeWithPrevious(_ session: RecordingSession) {
        guard let previous = previous(of: session), let last = previous.recordings.last else { return }
        let first = session.recordings[0]
        // Undo a manual split if that is all that separates them; otherwise force the merge.
        let automatic = grouper.decision(previous: last, next: first)
        setOverride(automatic.joinsPrevious ? nil : .merge, for: first)
    }

    func canSplit(_ session: RecordingSession, before recording: SourceRecording) -> Bool {
        session.recordings.first != recording && session.recordings.contains(recording)
    }

    func split(_ session: RecordingSession, before recording: SourceRecording) {
        guard let index = session.recordings.firstIndex(of: recording), index > 0 else { return }
        let automatic = grouper.decision(previous: session.recordings[index - 1], next: recording)
        setOverride(automatic.joinsPrevious ? .split : nil, for: recording)
    }

    // MARK: Selection and import status

    /// At least one of its chunks already belongs to an import (of this or a differently grouped session).
    func hasImportedChunks(_ session: RecordingSession) -> Bool {
        session.recordings.contains { importedSources[$0.fingerprint] != nil }
    }

    func isSelected(_ session: RecordingSession) -> Bool {
        session.recordings.allSatisfy { selectedRecordings.contains($0.fingerprint) }
    }

    func setSelected(_ selected: Bool, _ session: RecordingSession) {
        let fingerprints = session.recordings.map(\.fingerprint)
        if selected { selectedRecordings.formUnion(fingerprints) } else { selectedRecordings.subtract(fingerprints) }
    }

    private func selectDefaults() {
        selectedRecordings = []
        for session in sessions
        where session.duration >= Self.autoSelectMinimumDuration && !hasImportedChunks(session) {
            setSelected(true, session)
        }
    }
}
