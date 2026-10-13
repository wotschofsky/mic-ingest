import Foundation

/// Where the identity of a diarized speaker currently comes from.
enum IdentityState: String, Codable {
    /// No identity. A perfectly valid end state.
    case unidentified
    /// Assigned by the resolver from voice and/or transcript evidence.
    case automatic
    /// Assigned (or confirmed) by the user.
    case manual
    /// The user decided this speaker stays unnamed; automation must not override it.
    case manualUnidentified = "manual_unidentified"
}

enum EvidenceSource: String, Codable {
    case manual
    case voiceMatch = "voice_match"
    case selfIdentification = "self_identification"
    case transcriptContext = "transcript_context"
}

/// One piece of identity evidence with its provenance. Evidence that did not lead to an assignment
/// is kept too (`applied == false`) so the reasoning stays inspectable.
struct IdentityEvidence: Codable, Hashable {
    var source: EvidenceSource
    /// Whether this evidence backs the speaker's current identity.
    var applied: Bool
    var personID: String?
    var name: String?
    /// Voice evidence: cosine similarity and the band it fell into.
    var similarity: Double?
    var band: String?
    /// Transcript evidence: the model's confidence and the utterance it points at.
    var confidence: String?
    var utteranceIndex: Int?
    var timestampMs: Int?
    var quote: String?
    var reason: String?
}

/// Maps one diarized cluster (AssemblyAI speaker label) to an optional known person and a display name.
struct SpeakerEntry: Codable, Hashable {
    var label: String
    var personID: String?
    var displayName: String
    var state: IdentityState
    var confidence: String?
    var evidence: [IdentityEvidence]
    var utteranceCount: Int
    var speechSeconds: Double

    static func defaultName(_ label: String) -> String { "Speaker \(label)" }
}

/// Our own, versioned sidecar (`*.metadata.json`). Together with the raw AssemblyAI response it is
/// enough to regenerate the Markdown transcript without transcribing again. Contains no secrets.
struct SessionMetadata: Codable {
    static let currentSchemaVersion = 1

    struct App: Codable { var name: String; var version: String }

    struct Session: Codable {
        var id: String
        var fingerprint: String
        var start: Date
        var end: Date
        /// IANA identifier of the zone clock times are written in (Markdown, file names).
        var timeZone: String
        /// Zone the recorder's clock was taken to run in when its filename timestamps were read.
        var recorderTimeZone: String?
        var durationSeconds: Double
        var transmitter: String
        var trim: Trim?
    }

    struct Source: Codable, Hashable {
        var filename: String
        var start: Date
        var durationSeconds: Double
        var frameCount: Int64
        var fileSizeBytes: Int64
        /// Where this chunk's first used sample sits inside the merged audio.
        var offsetSeconds: Double
        /// Seconds cut from the start of this file by a trim (nil: none).
        var skippedSeconds: Double?
    }

    /// The part of the recorded session that was imported, if its ends were trimmed.
    struct Trim: Codable, Hashable {
        /// Seconds from the session's first recorded sample.
        var startSeconds: Double
        var endSeconds: Double
        var untrimmedDurationSeconds: Double
    }

    struct Audio: Codable {
        var filename: String
        var container: ArchiveContainer
        var sampleRate: Double
        var channels: Int
        var bitDepth: Int
        var isFloat: Bool
        var frameCount: Int64
        var pcmSHA256: String
    }

    struct Transcription: Codable {
        var provider = "assemblyai"
        var transcriptID: String
        var requestedModels: [String]
        var modelUsed: String?
        var languageCodes: [String]
        var languageDetected: String?
        var speakerLabels = true
        var prompt: String?
        /// What was sent for transcription: the archive itself or a 16 kHz rendition of it.
        var uploadedAudio: String?
        var submittedAt: Date
        var completedAt: Date?
        var rawResponseFilename: String?
    }

    struct IdentityInference: Codable {
        struct LLM: Codable {
            var provider = "groq"
            var model: String
            /// `ok`, `failed` or `skipped`.
            var status: String
            var error: String?
        }
        struct Voice: Codable {
            var model: String
            var version: String
            var dimension: Int
            var status: String
            var error: String?
            var thresholds: VoiceThresholds
        }
        var llm: LLM?
        var voice: Voice?
    }

    struct Processing: Codable {
        var stage: String
        var processedAt: Date
        var warnings: [String]
    }

    var schemaVersion = SessionMetadata.currentSchemaVersion
    var app: App
    var session: Session
    var sources: [Source]
    var audio: Audio
    var transcription: Transcription?
    var speakers: [SpeakerEntry] = []
    var identityInference = IdentityInference()
    var processing: Processing

    var timeline: SessionTimeline {
        SessionTimeline(chunks: sources.map {
            .init(offsetSeconds: $0.offsetSeconds, start: $0.start.addingTimeInterval($0.skippedSeconds ?? 0))
        },
                        timeZone: TimeZone(identifier: session.timeZone) ?? .current)
    }

    func displayName(for label: String) -> String {
        speakers.first { $0.label == label }?.displayName ?? SpeakerEntry.defaultName(label)
    }

    // MARK: Coding

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // ISO 8601 with the session's UTC offset is written by `encoded()`; this is the fallback.
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// JSON with dates in ISO 8601 carrying the local UTC offset of the session's time zone.
    func encoded() throws -> Data {
        let zone = TimeZone(identifier: session.timeZone) ?? .current
        let encoder = Self.encoder
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Date.ISO8601FormatStyle(
                dateSeparator: .dash, dateTimeSeparator: .standard, timeSeparator: .colon,
                timeZoneSeparator: .colon, includingFractionalSeconds: true, timeZone: zone)))
        }
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> SessionMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            for style in [Date.ISO8601FormatStyle(includingFractionalSeconds: true), Date.ISO8601FormatStyle()] {
                if let date = try? style.parse(string) { return date }
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(string)"))
        }
        return try decoder.decode(SessionMetadata.self, from: data)
    }
}

/// Converts positions in the merged audio to wall-clock time. Piecewise per source chunk, so a
/// manually merged session with gaps between its files still shows the right clock times.
struct SessionTimeline {
    struct Chunk {
        var offsetSeconds: Double
        var start: Date
    }

    var chunks: [Chunk]
    var timeZone: TimeZone

    func date(atMs milliseconds: Int) -> Date {
        let seconds = Double(milliseconds) / 1000
        let chunk = chunks.last { $0.offsetSeconds <= seconds } ?? chunks.first
        guard let chunk else { return Date(timeIntervalSince1970: seconds) }
        return chunk.start.addingTimeInterval(seconds - chunk.offsetSeconds)
    }

    /// `20:44:03`, in the session's time zone.
    func clockTime(atMs milliseconds: Int) -> String {
        Self.clock(date(atMs: milliseconds), in: timeZone)
    }

    static func clock(_ date: Date, in timeZone: TimeZone, seconds: Bool = true) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return seconds
            ? String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
            : String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
