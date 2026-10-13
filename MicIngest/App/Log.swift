import OSLog

/// Structured logging. Never pass API keys, auth headers, embeddings or transcript text here.
enum Log {
    static let source = Logger(subsystem: AppConfig.logSubsystem, category: "source")
    static let grouping = Logger(subsystem: AppConfig.logSubsystem, category: "grouping")
    static let audio = Logger(subsystem: AppConfig.logSubsystem, category: "audio")
    static let pipeline = Logger(subsystem: AppConfig.logSubsystem, category: "import")
    static let network = Logger(subsystem: AppConfig.logSubsystem, category: "network")
    static let identity = Logger(subsystem: AppConfig.logSubsystem, category: "identity")
    static let persistence = Logger(subsystem: AppConfig.logSubsystem, category: "persistence")
}
