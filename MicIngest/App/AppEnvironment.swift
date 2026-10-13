import Foundation

/// Builds the app's services and models once and hands them to the UI. Wiring only: each piece
/// (source, import, library, people, identity) lives in its own type.
@MainActor
final class AppEnvironment {
    let database: AppDatabase
    let keychain: KeychainStore
    let settings: AppSettings
    let assemblyAI: AssemblyAIClient
    let groq: GroqClient
    let identity: IdentityService
    let pipeline: ImportPipeline
    let source: SourceModel
    let imports: ImportCoordinator
    let library: LibraryModel
    let people: PeopleModel
    let initialSource: URL?

    init() throws {
        var keychain = KeychainStore()
        var settings = AppSettings()
        var assemblyAIURL = AppConfig.AssemblyAI.baseURL
        var groqURL = AppConfig.Groq.baseURL
        var databaseName: String?
        var initialSource: URL?
        var initialDestination: URL?

        #if DEBUG
        // Development and UI-test hooks. A profile isolates database, preferences and Keychain items
        // from the real ones; the URL overrides point the clients at a local stand-in server.
        let environment = ProcessInfo.processInfo.environment
        if let profile = environment["MICINGEST_PROFILE"], !profile.isEmpty {
            keychain.service += ".\(profile)"
            settings.defaults = UserDefaults(suiteName: "\(AppConfig.keychainService).\(profile)") ?? .standard
            databaseName = profile
        }
        if let url = environment["MICINGEST_ASSEMBLYAI_URL"].flatMap(URL.init(string:)) { assemblyAIURL = url }
        if let url = environment["MICINGEST_GROQ_URL"].flatMap(URL.init(string:)) { groqURL = url }
        initialSource = environment["MICINGEST_SOURCE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        initialDestination = environment["MICINGEST_DESTINATION"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        #endif

        self.keychain = keychain
        self.settings = settings
        self.initialSource = initialSource
        database = try AppDatabase.onDisk(profile: databaseName)
        assemblyAI = AssemblyAIClient(baseURL: assemblyAIURL) { keychain.get(.assemblyAI) }
        groq = GroqClient(baseURL: groqURL) { keychain.get(.groq) }
        identity = IdentityService(database: database, embedder: SpeakerEmbedder(), groq: groq, settings: settings)
        pipeline = ImportPipeline(database: database, assemblyAI: assemblyAI, identity: identity, settings: settings)
        source = SourceModel(database: database, settings: settings)
        imports = ImportCoordinator(pipeline: pipeline, database: database, settings: settings)
        library = LibraryModel(database: database)
        people = PeopleModel(database: database, identity: identity, settings: settings)
        if let initialDestination { imports.select(initialDestination) }
    }

    func transcriptModel(for sessionID: String) -> TranscriptModel {
        TranscriptModel(sessionID: sessionID, database: database, identity: identity, pipeline: pipeline)
    }
}
