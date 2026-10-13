import Foundation

/// Non-secret preferences in UserDefaults. API keys are never stored here (see `KeychainStore`).
struct AppSettings {
    var defaults: UserDefaults = .standard

    private enum Key {
        static let prompt = "transcriptionPrompt"
        static let groqModel = "groqModel"
        static let thresholds = "voiceThresholds"
        static let destinationBookmark = "destinationBookmark"
        static let sourceBookmark = "sourceBookmark"
        static let recorderUTCOffset = "recorderUTCOffsetSeconds"
        static let libraries = "libraries"
    }

    /// Contextual description of the audio sent to AssemblyAI. Empty means "send no prompt".
    var transcriptionPrompt: String {
        get { defaults.string(forKey: Key.prompt) ?? AppConfig.AssemblyAI.defaultPrompt }
        nonmutating set { defaults.set(newValue, forKey: Key.prompt) }
    }

    var groqModel: String {
        get {
            let stored = defaults.string(forKey: Key.groqModel)?.trimmingCharacters(in: .whitespaces) ?? ""
            return stored.isEmpty ? AppConfig.Groq.defaultModel : stored
        }
        nonmutating set { defaults.set(newValue, forKey: Key.groqModel) }
    }

    var voiceThresholds: VoiceThresholds {
        get {
            defaults.data(forKey: Key.thresholds).flatMap { try? JSONDecoder().decode(VoiceThresholds.self, from: $0) } ?? .default
        }
        nonmutating set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.thresholds) }
    }

    /// Zone the recorder's clock runs in. The recorder stamps files with its own clock and knows no
    /// time zone; a clock still on its factory setting is hours off local time. nil: same as this Mac.
    /// Not preset: there is no way to read the true zone from the files (the `bext`/`iXML` chunks are
    /// empty), so the user chooses it. DJI's factory clock is believed to run on UTC+8.
    var recorderTimeZone: TimeZone? {
        get { (defaults.object(forKey: Key.recorderUTCOffset) as? Int).flatMap(TimeZone.init(secondsFromGMT:)) }
        nonmutating set { defaults.set(newValue?.secondsFromGMT(), forKey: Key.recorderUTCOffset) }
    }

    /// Every library folder the app has been pointed at (personal, work, …), in the order added.
    /// Kept by path as well as bookmark, so a library on a drive that is offline stays in the list.
    var libraries: [URL] {
        get {
            (defaults.array(forKey: Key.libraries) as? [[String: Any]] ?? []).compactMap { entry in
                FolderAccess.resolve(entry["bookmark"] as? Data)
                    ?? (entry["path"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
            }
        }
        nonmutating set {
            defaults.set(newValue.map { url -> [String: Any] in
                var entry: [String: Any] = ["path": url.path]
                if let bookmark = FolderAccess.bookmark(for: url) { entry["bookmark"] = bookmark }
                return entry
            }, forKey: Key.libraries)
        }
    }

    /// The library currently in use: where imports go and whose transcripts are listed.
    var destination: URL? {
        get { FolderAccess.resolve(defaults.data(forKey: Key.destinationBookmark)) }
        nonmutating set { defaults.set(newValue.flatMap(FolderAccess.bookmark), forKey: Key.destinationBookmark) }
    }

    /// Manually chosen source folder, reopened on the next launch.
    var sourceFolder: URL? {
        get { FolderAccess.resolve(defaults.data(forKey: Key.sourceBookmark)) }
        nonmutating set { defaults.set(newValue.flatMap(FolderAccess.bookmark), forKey: Key.sourceBookmark) }
    }
}
