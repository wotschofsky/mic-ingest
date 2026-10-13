import Foundation

/// What the LLM (and, after validation, the app) believes about one diarized speaker's name.
struct NameFinding: Codable, Equatable {
    enum Confidence: String, Codable, Comparable {
        case low, medium, high
        private var rank: Int { self == .high ? 2 : self == .medium ? 1 : 0 }
        static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    }

    enum Basis: String, Codable {
        case selfIdentification = "self_identification"
        case addressedByName = "addressed_by_name"
        case introducedByOther = "introduced_by_other"
        case context
        case none
    }

    struct Evidence: Codable, Equatable {
        var utteranceId: String
        var quote: String
        var reason: String
    }

    var speaker: String
    var suggestedName: String?
    var confidence: Confidence
    var basis: Basis
    var evidence: [Evidence]

    /// The only kind of transcript evidence strong enough to name someone without voice support.
    var isExplicitSelfIdentification: Bool {
        suggestedName != nil && basis == .selfIdentification && confidence == .high
    }
}

struct NameFindings: Codable, Equatable {
    var speakers: [NameFinding]
}

/// Finds evidence in the diarized transcript that maps speaker labels to names.
/// The LLM proposes; `validate` and `reconcile` (plain code) decide what survives.
enum SpeakerNameInference {
    static let schemaName = "speaker_identity_evidence"

    /// Strict JSON Schema for Groq structured output: every field required, no extra properties.
    static let schema: JSONValue = [
        "type": "object",
        "additionalProperties": false,
        "required": ["speakers"],
        "properties": [
            "speakers": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["speaker", "suggestedName", "confidence", "basis", "evidence"],
                    "properties": [
                        "speaker": ["type": "string"],
                        "suggestedName": ["type": ["string", "null"]],
                        "confidence": ["type": "string", "enum": ["high", "medium", "low"]],
                        "basis": ["type": "string", "enum": ["self_identification", "addressed_by_name",
                                                             "introduced_by_other", "context", "none"]],
                        "evidence": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "additionalProperties": false,
                                "required": ["utteranceId", "quote", "reason"],
                                "properties": [
                                    "utteranceId": ["type": "string"],
                                    "quote": ["type": "string"],
                                    "reason": ["type": "string"],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ],
    ]

    static let systemPrompt = """
        You analyse a diarized transcript of a passive, everyday recording (mostly German, some English). \
        Speakers are labelled with letters by an automatic diarizer. Your only task is to find evidence in \
        the text for the real first name of each speaker label.

        Rules:
        - Do not guess. Most speakers cannot be named from a transcript, and that is the expected, valid outcome: \
        return suggestedName null, confidence "low", basis "none" and an empty evidence list for them.
        - A speaker mentioning a name is NOT evidence that the speaker has that name. \
        "Alex hat mir gestern erzählt, dass …" says nothing about who is speaking, except that it is probably not Alex.
        - Self-identification ("Hi, ich bin Sam", "Sam hier", "my name is Sam") is strong evidence for the \
        speaker of that utterance. Use basis "self_identification" only for this.
        - Introducing someone ("Das hier ist Robert") shows Robert is present. It does not name the speaker, and it \
        names another speaker only if the conversation makes clear which label Robert is.
        - Addressing someone ("Sam, was denkst du?") followed by a reply may indicate that the replying speaker \
        is Sam. Use basis "addressed_by_name", and confidence "high" only if it happens consistently; one \
        instance is "medium" at most. The person asking is NOT Sam.
        - Other conversational clues are basis "context" and never more than "medium".
        - Names of known people may be listed. They are only spelling hints for names you actually find in the \
        transcript; never assign one without evidence in the text.
        - Every suggested name needs at least one evidence item: the utteranceId exactly as given in brackets, a \
        short verbatim quote copied from that utterance, and one sentence explaining the reasoning.
        - Use the name exactly as it appears in the transcript. Return one entry for every speaker label in the excerpt.
        """

    // MARK: Chunking

    struct Chunk: Equatable {
        var utterances: Range<Int>
    }

    /// Splits a long transcript into sections that fit comfortably in one request, with a few
    /// utterances of overlap so an address and its reply are not separated at a boundary.
    static func chunks(for transcript: Transcript, characterBudget: Int = AppConfig.Groq.chunkCharacterBudget,
                       overlap: Int = AppConfig.Groq.chunkOverlapUtterances) -> [Chunk] {
        let utterances = transcript.utterances
        guard !utterances.isEmpty else { return [] }
        var chunks: [Chunk] = []
        var start = 0
        while start < utterances.count {
            var end = start, size = 0
            while end < utterances.count, end == start || size + utterances[end].text.count + 24 <= characterBudget {
                size += utterances[end].text.count + 24
                end += 1
            }
            chunks.append(Chunk(utterances: start..<end))
            if end >= utterances.count { break }
            start = max(end - overlap, start + 1)
        }
        return chunks
    }

    static func utteranceID(_ index: Int) -> String { "u\(index)" }

    /// The transcript text sent to the LLM for one chunk. Nothing else leaves the machine.
    static func userPrompt(chunk: Chunk, transcript: Transcript, knownNames: [String]) -> String {
        var lines: [String] = []
        if !knownNames.isEmpty {
            lines.append("Known people (spelling hints only): \(knownNames.sorted().joined(separator: ", "))")
            lines.append("")
        }
        lines.append("Transcript excerpt:")
        for utterance in transcript.utterances[chunk.utterances] {
            lines.append("[\(utteranceID(utterance.index))] Speaker \(utterance.speaker): \(utterance.text)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Validation

    private static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let scalars = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    private static func mentions(_ name: String, in text: String) -> Bool {
        let words = normalize(text).split(separator: " ").map(String.init)
        let nameWords = normalize(name).split(separator: " ").map(String.init)
        guard !nameWords.isEmpty, nameWords.count <= words.count else { return false }
        return (0...(words.count - nameWords.count)).contains { Array(words[$0..<($0 + nameWords.count)]) == nameWords }
    }

    /// Checks one chunk's model output against the transcript. Anything not anchored in the text is
    /// dropped: unknown speakers, citations of utterances outside the chunk, quotes that are not in
    /// the cited utterance, and names that never occur in the cited utterances.
    static func validate(_ output: NameFindings, chunk: Chunk, transcript: Transcript) -> [NameFinding] {
        let speakers = Set(transcript.utterances[chunk.utterances].map(\.speaker))
        var result: [NameFinding] = []
        for var finding in output.speakers {
            finding.speaker = finding.speaker.replacingOccurrences(of: "Speaker ", with: "")
            guard speakers.contains(finding.speaker),
                  let name = finding.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, name.count <= 40,
                  !normalize(name).hasPrefix("speaker"), !["unknown", "unbekannt", "null", "none"].contains(normalize(name))
            else { continue }

            var cited: [(evidence: NameFinding.Evidence, utterance: TranscriptUtterance)] = []
            for evidence in finding.evidence {
                guard evidence.utteranceId.hasPrefix("u"), let index = Int(evidence.utteranceId.dropFirst()),
                      chunk.utterances.contains(index) else { continue }
                let utterance = transcript.utterances[index]
                let quote = normalize(evidence.quote)
                guard !quote.isEmpty, normalize(utterance.text).contains(quote) else { continue }
                cited.append((evidence, utterance))
            }
            // The name itself has to occur in the text the model points at.
            guard cited.contains(where: { mentions(name, in: $0.utterance.text) }) else { continue }

            finding.suggestedName = name
            finding.evidence = cited.map(\.evidence)
            if finding.basis == .none { finding.basis = .context }
            if finding.basis == .selfIdentification {
                // Self-identification must come out of the speaker's own mouth.
                let ownWords = cited.contains { $0.utterance.speaker == finding.speaker && mentions(name, in: $0.utterance.text) }
                if !ownWords { finding.basis = .context }
            }
            if finding.basis == .context || finding.basis == .introducedByOther {
                finding.confidence = min(finding.confidence, .medium)
            }
            result.append(finding)
        }
        return result
    }

    // MARK: Reconciliation

    /// Combines validated findings from all chunks into at most one name per speaker. Pure code:
    /// it only selects among validated findings and so cannot introduce evidence of its own.
    static func reconcile(_ findings: [NameFinding]) -> [String: NameFinding] {
        var perSpeaker: [String: NameFinding] = [:]
        for (speaker, group) in Dictionary(grouping: findings, by: \.speaker) {
            // Merge findings for the same name across chunks.
            var byName: [String: NameFinding] = [:]
            for finding in group {
                guard let name = finding.suggestedName else { continue }
                let key = normalize(name)
                if var existing = byName[key] {
                    existing.evidence += finding.evidence.filter { !existing.evidence.contains($0) }
                    if finding.isExplicitSelfIdentification || (!existing.isExplicitSelfIdentification && finding.confidence > existing.confidence) {
                        existing.basis = finding.basis
                        existing.confidence = finding.confidence
                    }
                    byName[key] = existing
                } else {
                    byName[key] = finding
                }
            }
            let explicit = byName.values.filter(\.isExplicitSelfIdentification)
            if explicit.count == 1 {
                perSpeaker[speaker] = explicit[0]
            } else if explicit.isEmpty, byName.count == 1, let only = byName.values.first {
                perSpeaker[speaker] = only
            }
            // Otherwise the evidence points at more than one name: leave the speaker unnamed.
        }
        // One name on several speakers: keep it only where it was explicitly self-stated.
        for (_, sameName) in Dictionary(grouping: perSpeaker.values, by: { normalize($0.suggestedName ?? "") }) where sameName.count > 1 {
            for finding in sameName where !finding.isExplicitSelfIdentification { perSpeaker[finding.speaker] = nil }
        }
        return perSpeaker
    }

    // MARK: Running

    /// Runs inference over the whole transcript. Throws if a request fails; findings are validated.
    static func infer(transcript: Transcript, knownNames: [String], model: String, client: GroqClient,
                      progress: (Int, Int) -> Void = { _, _ in }) async throws -> [String: NameFinding] {
        let chunks = chunks(for: transcript)
        var findings: [NameFinding] = []
        for (number, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            progress(number, chunks.count)
            let data = try await withRateLimitRetry {
                try await client.structuredCompletion(
                    model: model, system: systemPrompt,
                    user: userPrompt(chunk: chunk, transcript: transcript, knownNames: knownNames),
                    schemaName: schemaName, schema: schema)
            }
            guard let output = try? JSONDecoder().decode(NameFindings.self, from: data) else {
                throw ServiceError(service: GroqClient.serviceName, kind: .invalidResponse, detail: "output did not match the schema")
            }
            findings += validate(output, chunk: chunk, transcript: transcript)
        }
        Log.identity.info("Name inference: \(chunks.count) chunks, \(findings.count) validated findings")
        return reconcile(findings)
    }

    /// Long transcripts on small rate limits hit 429s; wait as told, a few times, then give up.
    private static func withRateLimitRetry<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do { return try await operation() } catch let error as ServiceError where error.isTransient && attempt < 4 {
                attempt += 1
                let wait = min(error.retryAfter ?? Double(attempt * 5), 90)
                Log.identity.info("Groq transient failure, retrying in \(wait, format: .fixed(precision: 0)) s")
                try await Task.sleep(for: .seconds(wait))
            }
        }
    }
}
