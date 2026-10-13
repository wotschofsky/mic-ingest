import AppKit
import Observation

/// Imported sessions as stored in the database, kept current by observation.
@MainActor
@Observable
final class LibraryModel {
    private(set) var sessions: [ImportedSession] = []
    private var observation: Task<Void, Never>?

    init(database: AppDatabase) {
        sessions = (try? database.sessions()) ?? []
        observation = Task { [weak self] in
            do {
                for try await sessions in database.observeSessions() { self?.sessions = sessions }
            } catch {
                Log.persistence.error("Session observation ended: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func session(id: String) -> ImportedSession? { sessions.first { $0.id == id } }
    func session(fingerprint: String) -> ImportedSession? { sessions.first { $0.fingerprint == fingerprint } }
}

/// Runs imports one after another and publishes their live progress. Owns the list of library
/// folders and which one is current.
@MainActor
@Observable
final class ImportCoordinator {
    /// All library folders the app knows (for example a personal one and a shared work one).
    private(set) var libraries: [URL] = []
    /// The current library: imports go here and its transcripts are the ones listed. Always visible,
    /// remembered between launches. Selecting a folder that already holds a library brings its
    /// sessions and people back.
    private(set) var destination: URL?
    /// Live progress by session ID, for sessions that are queued or running.
    private(set) var progress: [String: ImportProgress] = [:]
    private(set) var lastError: String?

    private let pipeline: ImportPipeline
    private let database: AppDatabase
    private let settings: AppSettings
    private var queue: [String] = []
    private var worker: Task<Void, Never>?
    private var current: (id: String, task: Task<Void, Never>)?

    init(pipeline: ImportPipeline, database: AppDatabase, settings: AppSettings) {
        self.pipeline = pipeline
        self.database = database
        self.settings = settings
        libraries = settings.libraries
        destination = settings.destination
        if let destination, !libraries.contains(where: { $0.path == destination.path }) {
            libraries.append(destination)
            settings.libraries = libraries
        }
        if let destination { try? database.adoptPeopleWithoutLibrary(into: destination.path) }
        markInterruptedSessions()
        let store = SessionStore(database: database)
        for session in (try? database.sessions()) ?? [] { store.migrateLegacyLayout(session) }
        syncLibrary()
    }

    /// Sessions that were mid-flight when the app last quit become resumable instead of looking busy forever.
    /// They are deliberately not resumed automatically: resuming may upload audio and cost money,
    /// so it waits for an explicit Resume.
    private func markInterruptedSessions() {
        for var session in (try? database.sessions()) ?? [] where session.stage != .complete && session.stage != .failed {
            session.lastActiveStage = session.stage
            session.stage = .failed
            session.failure = "The app quit while this import was running. Resume to continue where it left off."
            try? database.save(session)
        }
    }

    // MARK: Libraries

    static func name(of library: URL) -> String { library.lastPathComponent }

    /// Asks for a folder and makes it the current library (adding it to the list if it is new).
    func addLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a library folder. Transcripts are saved there as Markdown, audio and data in its Data folder."
        panel.directoryURL = destination
        if panel.runModal() == .OK, let url = panel.url { select(url) }
    }

    func select(_ library: URL) {
        if !libraries.contains(where: { $0.path == library.path }) {
            libraries.append(library)
            settings.libraries = libraries
        }
        destination = library
        settings.destination = library
        syncLibrary()
    }

    /// Takes the library out of the app. Its folder, transcripts and audio stay exactly as they are
    /// and can be added again later.
    func remove(_ library: URL) {
        libraries.removeAll { $0.path == library.path }
        settings.libraries = libraries
        try? database.removeLibrary(path: library.path)
        if destination?.path == library.path {
            destination = libraries.first
            settings.destination = destination
            syncLibrary()
        }
    }

    /// Picks up what changed in the folder from outside: sessions imported on another Mac or by
    /// someone the library is shared with, and people they added.
    func reloadLibrary() { syncLibrary() }

    /// Brings database and library folder in line: people and voice profiles from the folder first
    /// (so nothing in it is overwritten), then the database's own, then any sessions only the folder knows.
    private func syncLibrary() {
        guard let destination else { return }
        let library = LibraryFolder(root: destination), database = database
        do {
            try library.mergePeople(into: database)
            try library.writePeople(from: database)
        } catch {
            Log.persistence.error("Could not sync people with the library: \(error.localizedDescription, privacy: .public)")
        }
        Task.detached(priority: .utility) {
            do { try library.restoreSessions(into: database) } catch {
                Log.persistence.error("Could not read the library folder: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func isActive(_ sessionID: String) -> Bool { progress[sessionID] != nil }
    var isBusy: Bool { !progress.isEmpty }

    /// Queues the sessions for import into the current destination.
    /// Queues the sessions for import into the current library, each limited to its trim if it has one.
    func importSessions(_ sessions: [RecordingSession], trims: [String: Trim] = [:]) {
        guard let destination else { return }
        lastError = nil
        for session in sessions {
            do {
                let record = try pipeline.register(session, destination: destination, trim: trims[session.fingerprint])
                if record.stage != .complete { enqueue(record.id) }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Continues a failed or interrupted session from the first stage that is not done yet.
    func resume(_ sessionID: String) {
        enqueue(sessionID)
    }

    func stop(_ sessionID: String) {
        queue.removeAll { $0 == sessionID }
        if current?.id == sessionID { current?.task.cancel() } else { progress[sessionID] = nil }
    }

    private func enqueue(_ sessionID: String) {
        guard progress[sessionID] == nil else { return }
        progress[sessionID] = ImportProgress(stage: .preparing)
        queue.append(sessionID)
        guard worker == nil else { return }
        // Import one session at a time. Parallel uploads if a multi-session import ever feels slow.
        worker = Task { [weak self] in
            while let self, let next = self.queue.first {
                self.queue.removeFirst()
                let task = Task { [pipeline = self.pipeline] in
                    await pipeline.run(sessionID: next) { update in
                        Task { @MainActor [weak self] in
                            guard let self, self.progress[next] != nil, update.stage != .complete, update.stage != .failed else { return }
                            self.progress[next] = update
                        }
                    }
                }
                self.current = (next, task)
                await task.value
                self.current = nil
                self.progress[next] = nil
            }
            self?.worker = nil
        }
    }
}
