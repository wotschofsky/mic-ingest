import Foundation

/// One diarized turn. `index` is its position in the transcript and doubles as a stable utterance ID.
struct TranscriptUtterance: Identifiable, Hashable {
    var index: Int
    var speaker: String
    var startMs: Int
    var endMs: Int
    var text: String
    var confidence: Double

    var id: Int { index }
    var durationMs: Int { endMs - startMs }
}

/// The app's read-only view of a finished transcription. Always derived from the raw AssemblyAI
/// response on disk; it is never edited, speaker names are layered on top by `SessionMetadata`.
struct Transcript {
    var id: String
    var utterances: [TranscriptUtterance]
    var modelUsed: String?
    var languageCode: String?

    /// Diarized speaker labels in order of first appearance.
    var speakers: [String] {
        var seen = Set<String>(), ordered: [String] = []
        for utterance in utterances where seen.insert(utterance.speaker).inserted { ordered.append(utterance.speaker) }
        return ordered
    }

    func speechSeconds(of speaker: String) -> Double {
        Double(utterances.lazy.filter { $0.speaker == speaker }.reduce(0) { $0 + $1.durationMs }) / 1000
    }

    init(id: String, utterances: [TranscriptUtterance], modelUsed: String? = nil, languageCode: String? = nil) {
        self.id = id
        self.utterances = utterances
        self.modelUsed = modelUsed
        self.languageCode = languageCode
    }

    init(_ response: AssemblyAITranscript) {
        var turns: [(speaker: String, start: Int, end: Int, text: String, confidence: Double)] = []
        if let utterances = response.utterances, !utterances.isEmpty {
            turns = utterances.map { ($0.speaker, $0.start, $0.end, $0.text, $0.confidence) }
        } else if let words = response.words, !words.isEmpty {
            // No utterances (diarization unavailable for this file): rebuild turns from the word
            // stream, breaking on speaker changes and long pauses.
            for word in words {
                let speaker = word.speaker ?? "A"
                if let last = turns.last, last.speaker == speaker, word.start - last.end < 1500 {
                    let count = Double(last.text.split(separator: " ").count)
                    turns[turns.count - 1] = (speaker, last.start, word.end, last.text + " " + word.text,
                                              (last.confidence * count + word.confidence) / (count + 1))
                } else {
                    turns.append((speaker, word.start, word.end, word.text, word.confidence))
                }
            }
        }
        self.init(
            id: response.id,
            utterances: turns.enumerated().map {
                TranscriptUtterance(index: $0.offset, speaker: $0.element.speaker, startMs: $0.element.start,
                                    endMs: $0.element.end, text: $0.element.text, confidence: $0.element.confidence)
            },
            modelUsed: response.speechModelUsed, languageCode: response.languageCode)
    }

    /// Decodes a raw `*.assemblyai.json` file.
    init(rawResponse data: Data) throws {
        self.init(try JSONDecoder().decode(AssemblyAITranscript.self, from: data))
    }
}
