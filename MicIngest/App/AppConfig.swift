import Foundation

/// Single place for names, model IDs and tunables. Change the working app name here
/// (and PRODUCT_NAME / PRODUCT_BUNDLE_IDENTIFIER in the Xcode project).
enum AppConfig {
    static let appName = "MicIngest"
    static let keychainService = "dev.wsky.MicIngest"
    static let logSubsystem = "dev.wsky.MicIngest"

    enum AssemblyAI {
        static let baseURL = URL(string: "https://api.assemblyai.com")!
        /// Pinned async (pre-recorded) model. Universal-3.6 Pro is the realtime model; do not use it here.
        /// Deliberately no `universal-2` fallback: a silent switch to another model would change
        /// results without anyone noticing. A job the pinned model cannot do fails visibly instead.
        static let speechModels = ["universal-3-5-pro"]
        /// The languages Universal-3.5 Pro code-switches between (the set must include "en").
        /// Sent instead of language detection: the API accepts only one of the two.
        static let languageCodes = ["de", "en"]
        /// AssemblyAI's prompt describes the audio; behavioural instructions are ignored by the model.
        static let defaultPrompt = """
            Passive recording from a clip-on microphone worn by one person going about their day. \
            The conversation is primarily German with occasional English words and sentences. \
            Several speakers, background conversations, noise, pauses and informal conversational speech.
            """
        static let pollInterval: Duration = .seconds(5)
    }

    enum Groq {
        static let baseURL = URL(string: "https://api.groq.com/openai/v1")!
        /// Production model with strict JSON Schema structured output.
        static let defaultModel = "openai/gpt-oss-120b"
        /// ~3.5k tokens of transcript per request: fits free-tier per-minute token limits.
        static let chunkCharacterBudget = 12_000
        static let chunkOverlapUtterances = 3
    }

    enum Grouping {
        /// DJI rolls over to a new file after this much audio.
        static let rolloverDuration: TimeInterval = 30 * 60
        /// A file within this much of the maximum counts as an automatic rollover.
        static let rolloverSlack: TimeInterval = 15
        /// Allowed difference between the expected and the actual start of the next file.
        static let timingTolerance: TimeInterval = 2
    }
}
