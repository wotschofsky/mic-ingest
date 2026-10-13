import XCTest
@testable import MicIngest

private func utterances(_ lines: [(String, String)]) -> Transcript {
    Transcript(id: "t", utterances: lines.enumerated().map { index, line in
        TranscriptUtterance(index: index, speaker: line.0, startMs: index * 10_000, endMs: index * 10_000 + 6000, text: line.1, confidence: 0.9)
    })
}

private func finding(_ speaker: String, _ name: String?, _ confidence: NameFinding.Confidence = .high,
                     _ basis: NameFinding.Basis = .selfIdentification, evidence: [(String, String)] = []) -> NameFinding {
    NameFinding(speaker: speaker, suggestedName: name, confidence: confidence, basis: basis,
                evidence: evidence.map { .init(utteranceId: $0.0, quote: $0.1, reason: "because") })
}

final class NameInferenceTests: XCTestCase {
    let transcript = utterances([
        ("A", "Alex hat mir gestern erzählt, dass er umzieht."),
        ("B", "Hi, ich bin Sam."),
        ("A", "Sam, was denkst du?"),
        ("B", "Ich finde das gut."),
        ("C", "Das hier ist Robert."),
    ])
    var chunk: SpeakerNameInference.Chunk { .init(utterances: 0..<5) }

    func testDecodesStructuredGroqOutput() throws {
        let json = """
        {"speakers": [
          {"speaker": "B", "suggestedName": "Sam", "confidence": "high", "basis": "self_identification",
           "evidence": [{"utteranceId": "u1", "quote": "ich bin Sam", "reason": "The speaker directly introduced themselves as Sam."}]},
          {"speaker": "C", "suggestedName": null, "confidence": "low", "basis": "none", "evidence": []}
        ]}
        """
        let output = try JSONDecoder().decode(NameFindings.self, from: Data(json.utf8))
        XCTAssertEqual(output.speakers.count, 2)
        XCTAssertEqual(output.speakers[0].suggestedName, "Sam")
        XCTAssertTrue(output.speakers[0].isExplicitSelfIdentification)
        XCTAssertNil(output.speakers[1].suggestedName)

        let validated = SpeakerNameInference.validate(output, chunk: chunk, transcript: transcript)
        XCTAssertEqual(validated.map(\.speaker), ["B"])
        XCTAssertEqual(validated[0].evidence.map(\.utteranceId), ["u1"])
    }

    func testRejectsOutputThatDoesNotMatchTheSchema() {
        for json in [#"{"speakers": [{"speaker": "B"}]}"#, #"{"speakers": [{"speaker": "B", "suggestedName": "J", "confidence": "certain", "basis": "none", "evidence": []}]}"#, "Speaker B is Sam."] {
            XCTAssertNil(try? JSONDecoder().decode(NameFindings.self, from: Data(json.utf8)), json)
        }
    }

    func testMentioningSomeoneIsNotSelfIdentification() {
        // The model wrongly claims A is Alex from "Alex hat mir gestern erzählt…".
        let output = NameFindings(speakers: [finding("A", "Alex", .high, .context, evidence: [("u0", "Alex hat mir gestern erzählt")])])
        let validated = SpeakerNameInference.validate(output, chunk: chunk, transcript: transcript)
        XCTAssertEqual(validated.count, 1)
        XCTAssertEqual(validated[0].confidence, .medium, "context evidence is capped")
        XCTAssertFalse(validated[0].isExplicitSelfIdentification)
    }

    func testSelfIdentificationMustBeSpokenByThatSpeaker() {
        // "Das hier ist Robert" was said by C about someone else; claiming A self-identified as Robert is invalid.
        let output = NameFindings(speakers: [finding("A", "Robert", .high, .selfIdentification, evidence: [("u4", "Das hier ist Robert")])])
        let validated = SpeakerNameInference.validate(output, chunk: chunk, transcript: transcript)
        XCTAssertEqual(validated.first?.basis, .context)
        XCTAssertFalse(validated.first?.isExplicitSelfIdentification ?? true)
    }

    func testFabricatedEvidenceIsDropped() {
        let output = NameFindings(speakers: [
            finding("B", "Sam", evidence: [("u3", "ich bin Sam")]),          // quote is not in u3
            finding("C", "Anna", evidence: [("u4", "Das hier ist Robert")]),       // name not in cited text
            finding("A", "Alex", evidence: [("u99", "ich bin Alex")]),           // utterance outside the chunk
            finding("Z", "Sam", evidence: [("u1", "ich bin Sam")]),          // unknown speaker
            finding("B", "Speaker B", evidence: [("u1", "ich bin Sam")]),       // not a name
            finding("B", "Sam", evidence: []),                                  // no evidence at all
        ])
        XCTAssertTrue(SpeakerNameInference.validate(output, chunk: chunk, transcript: transcript).isEmpty)
    }

    func testAcceptsSpeakerPrefixAndQuotePunctuationDifferences() {
        let output = NameFindings(speakers: [finding("Speaker B", "Sam", evidence: [("u1", "Hi ich bin SAM")])])
        let validated = SpeakerNameInference.validate(output, chunk: chunk, transcript: transcript)
        XCTAssertEqual(validated.map(\.speaker), ["B"])
        XCTAssertTrue(validated[0].isExplicitSelfIdentification)
    }

    func testNameMustMatchWholeWords() {
        let transcript = utterances([("A", "Ich bin Samantha, hallo.")])
        let output = NameFindings(speakers: [finding("A", "Sam", evidence: [("u0", "Ich bin Samantha")])])
        XCTAssertTrue(SpeakerNameInference.validate(output, chunk: .init(utterances: 0..<1), transcript: transcript).isEmpty)
    }

    func testReconcileKeepsExplicitSelfIdentificationOverContext() {
        let result = SpeakerNameInference.reconcile([
            finding("B", "Sam", .high, .selfIdentification, evidence: [("u1", "ich bin Sam")]),
            finding("B", "Robert", .medium, .context, evidence: [("u4", "Robert")]),
            finding("B", "sam", .medium, .addressedByName, evidence: [("u2", "Sam, was denkst du")]),
        ])
        XCTAssertEqual(result["B"]?.suggestedName, "Sam")
        XCTAssertEqual(result["B"]?.evidence.count, 2, "evidence for the same name is merged across chunks")
        XCTAssertTrue(result["B"]?.isExplicitSelfIdentification ?? false)
    }

    func testReconcileLeavesConflictsUnnamed() {
        let conflicting = SpeakerNameInference.reconcile([
            finding("A", "Anna", .medium, .addressedByName, evidence: [("u1", "Anna")]),
            finding("A", "Maria", .medium, .addressedByName, evidence: [("u2", "Maria")]),
        ])
        XCTAssertNil(conflicting["A"])

        let twoSelfIdentifications = SpeakerNameInference.reconcile([
            finding("A", "Anna", evidence: [("u1", "ich bin Anna")]),
            finding("A", "Maria", evidence: [("u2", "ich bin Maria")]),
        ])
        XCTAssertNil(twoSelfIdentifications["A"])
    }

    func testReconcileDoesNotGiveOneNameToTwoSpeakersOnWeakEvidence() {
        let result = SpeakerNameInference.reconcile([
            finding("A", "Sam", .medium, .addressedByName, evidence: [("u1", "Sam")]),
            finding("B", "Sam", .high, .selfIdentification, evidence: [("u2", "ich bin Sam")]),
            finding("C", "Sam", .medium, .context, evidence: [("u3", "Sam")]),
        ])
        XCTAssertEqual(Set(result.keys), ["B"])
    }

    func testChunkingCoversEverythingWithOverlapAndStaysInBudget() {
        let long = utterances((0..<400).map { ($0 % 2 == 0 ? "A" : "B", String(repeating: "wort ", count: 40)) })
        let chunks = SpeakerNameInference.chunks(for: long, characterBudget: 5000, overlap: 3)
        XCTAssertGreaterThan(chunks.count, 10)
        XCTAssertEqual(chunks.first?.utterances.lowerBound, 0)
        XCTAssertEqual(chunks.last?.utterances.upperBound, 400)
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(next.utterances.lowerBound, previous.utterances.upperBound - 3)
        }
        for chunk in chunks {
            XCTAssertLessThanOrEqual(long.utterances[chunk.utterances].reduce(0) { $0 + $1.text.count + 24 }, 5000)
        }
        // A single oversized utterance still gets its own chunk instead of looping forever.
        let huge = utterances([("A", String(repeating: "x", count: 20_000)), ("B", "kurz")])
        XCTAssertEqual(SpeakerNameInference.chunks(for: huge, characterBudget: 5000).map(\.utterances), [0..<1, 1..<2])
        XCTAssertTrue(SpeakerNameInference.chunks(for: utterances([])).isEmpty)
    }

    func testPromptContainsUtteranceIDsAndOnlyTranscriptText() {
        let prompt = SpeakerNameInference.userPrompt(chunk: .init(utterances: 1..<3), transcript: transcript, knownNames: ["Robert", "Anna"])
        XCTAssertTrue(prompt.contains("[u1] Speaker B: Hi, ich bin Sam."))
        XCTAssertTrue(prompt.contains("[u2] Speaker A: Sam, was denkst du?"))
        XCTAssertFalse(prompt.contains("[u0]"))
        XCTAssertTrue(prompt.contains("Known people (spelling hints only): Anna, Robert"))
    }

    func testSchemaIsStrict() throws {
        let data = try JSONEncoder().encode(SpeakerNameInference.schema)
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func checkObjects(_ node: Any) {
            guard let object = node as? [String: Any] else { return }
            if object["type"] as? String == "object" {
                XCTAssertEqual(object["additionalProperties"] as? Bool, false)
                let properties = (object["properties"] as? [String: Any]) ?? [:]
                XCTAssertEqual(Set(object["required"] as? [String] ?? []), Set(properties.keys), "strict mode: every field required")
            }
            for value in object.values {
                checkObjects(value)
            }
        }
        checkObjects(schema)
    }
}

final class VoiceMatcherTests: XCTestCase {
    let thresholds = VoiceThresholds(strong: 0.6, enroll: 0.7, borderline: 0.45, margin: 0.1)

    /// Unit vector at `degrees` in the plane, padded to more dimensions.
    private func vector(_ degrees: Double) -> [Float] {
        [Float(cos(degrees * .pi / 180)), Float(sin(degrees * .pi / 180)), 0, 0]
    }

    func testBands() {
        let probe = vector(0)
        func band(_ degrees: Double) -> VoiceBand {
            VoiceMatcher.match(probe, profiles: ["p": [vector(degrees)]], thresholds: thresholds).band
        }
        XCTAssertEqual(band(30), .strong)       // cos 0.87
        XCTAssertEqual(band(58), .borderline)   // cos 0.53
        XCTAssertEqual(band(75), .unknown)      // cos 0.26
    }

    func testClosestPersonIsNotAutomaticallyAMatch() {
        let match = VoiceMatcher.match(vector(0), profiles: ["sam": [vector(80)], "anna": [vector(85)]], thresholds: thresholds)
        XCTAssertEqual(match.best?.personID, "sam", "there is always a closest voice")
        XCTAssertEqual(match.band, .unknown)
    }

    func testStrongScoreWithoutClearLeadIsOnlyBorderline() {
        let match = VoiceMatcher.match(vector(0), profiles: ["sam": [vector(30)], "twin": [vector(33)]], thresholds: thresholds)
        XCTAssertEqual(match.band, .borderline)
    }

    func testBestSampleCountsSoProfilesCanHoldSeveralConditions() {
        let match = VoiceMatcher.match(vector(0), profiles: ["sam": [vector(85), vector(20), vector(70)]], thresholds: thresholds)
        XCTAssertEqual(match.best?.similarity ?? 0, cos(20 * .pi / 180), accuracy: 0.001)
        XCTAssertEqual(match.band, .strong)
    }

    func testNoProfilesMeansUnknown() {
        XCTAssertEqual(VoiceMatcher.match(vector(0), profiles: [:], thresholds: thresholds), VoiceMatch(candidates: [], band: .unknown))
    }

    func testCentroidIsNormalised() throws {
        let centroid = try XCTUnwrap(VoiceMatcher.centroid([vector(0), vector(90)]))
        XCTAssertEqual(VoiceMatcher.cosine(centroid, vector(45)), 1, accuracy: 0.0001)
        XCTAssertNil(VoiceMatcher.centroid([]))
    }
}

final class ExcerptSelectorTests: XCTestCase {
    private func utterance(_ index: Int, _ speaker: String, _ start: Double, _ length: Double, confidence: Double = 0.9) -> TranscriptUtterance {
        TranscriptUtterance(index: index, speaker: speaker, startMs: Int(start * 1000), endMs: Int((start + length) * 1000), text: "…", confidence: confidence)
    }

    func testPrefersCleanLongConfidentSpeech() {
        let transcript = Transcript(id: "t", utterances: [
            utterance(0, "A", 0, 1.2),                      // one-word fragment
            utterance(1, "A", 5, 6),                        // good
            utterance(2, "B", 12, 8),
            utterance(3, "A", 21, 14),                      // good, capped at 10 s
            utterance(4, "A", 40, 5, confidence: 0.3),      // unreliable
            utterance(5, "A", 50, 6),                       // overlapped by B
            utterance(6, "B", 54, 4),
        ])
        let excerpts = ExcerptSelector().excerpts(for: "A", in: transcript)
        XCTAssertEqual(excerpts, [SpeechExcerpt(startMs: 5000, endMs: 11_000), SpeechExcerpt(startMs: 21_000, endMs: 31_000)])
    }

    func testTooLittleSpeechYieldsNothing() {
        let transcript = Transcript(id: "t", utterances: [utterance(0, "A", 0, 4), utterance(1, "B", 5, 2), utterance(2, "A", 8, 4)])
        XCTAssertTrue(ExcerptSelector().excerpts(for: "A", in: transcript).isEmpty, "8 s in total is below the minimum")
        XCTAssertTrue(ExcerptSelector().excerpts(for: "B", in: transcript).isEmpty)
    }

    func testCapsNumberOfExcerpts() {
        let transcript = Transcript(id: "t", utterances: (0..<30).map { utterance($0, "A", Double($0) * 10, 5) })
        XCTAssertEqual(ExcerptSelector().excerpts(for: "A", in: transcript).count, 8)
    }
}

final class IdentityResolverTests: XCTestCase {
    let sam = Person(id: "sam", displayName: "Sam", createdAt: Date(timeIntervalSince1970: 0))
    let anna = Person(id: "anna", displayName: "Anna", createdAt: Date(timeIntervalSince1970: 0))
    let thresholds = VoiceThresholds(strong: 0.6, enroll: 0.7, borderline: 0.45, margin: 0.1)

    private var resolver: IdentityResolver {
        IdentityResolver(people: [sam, anna], peopleWithVoiceProfile: ["sam", "anna"], thresholds: thresholds)
    }

    private func voice(_ personID: String, _ similarity: Double, _ band: VoiceBand) -> VoiceMatch {
        VoiceMatch(candidates: [VoiceCandidate(personID: personID, similarity: similarity)], band: band)
    }

    private func selfID(_ name: String) -> NameFinding {
        finding("B", name, .high, .selfIdentification, evidence: [("u1", "ich bin \(name)")])
    }

    func testManualAssignmentOverridesEverything() {
        let resolution = resolver.resolve(ResolverInput(label: "B", manual: .person("anna"),
                                                        voice: voice("sam", 0.9, .strong), finding: selfID("Sam")))
        XCTAssertEqual(resolution.outcome, .person("anna"))
        XCTAssertEqual(resolution.state, .manual)
        XCTAssertEqual(resolution.enrollment, .manualConfirmation)
        XCTAssertEqual(resolution.evidence.first, IdentityEvidence(source: .manual, applied: true, personID: "anna"))
        XCTAssertFalse(resolution.evidence.dropFirst().contains { $0.applied }, "automatic evidence is kept but not applied")
    }

    func testManualKeepUnidentifiedBlocksAutomation() {
        let resolution = resolver.resolve(ResolverInput(label: "B", manual: .unidentified,
                                                        voice: voice("sam", 0.9, .strong), finding: selfID("Sam")))
        XCTAssertEqual(resolution.outcome, .unidentified)
        XCTAssertEqual(resolution.state, .manualUnidentified)
        XCTAssertNil(resolution.enrollment)
    }

    func testStrongVoicePlusSelfIdentificationIsVeryHighConfidence() {
        let resolution = resolver.resolve(ResolverInput(label: "B", voice: voice("sam", 0.82, .strong), finding: selfID("Sam"),
                                                        utteranceStartMs: [1: 192_420]))
        XCTAssertEqual(resolution.outcome, .person("sam"))
        XCTAssertEqual(resolution.state, .automatic)
        XCTAssertEqual(resolution.confidence, "very_high")
        XCTAssertEqual(Set(resolution.evidence.filter(\.applied).map(\.source)), [.voiceMatch, .selfIdentification])
        XCTAssertEqual(resolution.evidence.first { $0.source == .selfIdentification }?.timestampMs, 192_420)
        XCTAssertEqual(resolution.evidence.first { $0.source == .selfIdentification }?.utteranceIndex, 1)
    }

    func testStrongVoiceAloneIdentifiesButOnlyEnrollsAboveEnrollThreshold() {
        let justStrong = resolver.resolve(ResolverInput(label: "B", voice: voice("sam", 0.63, .strong)))
        XCTAssertEqual(justStrong.outcome, .person("sam"))
        XCTAssertEqual(justStrong.confidence, "high")
        XCTAssertNil(justStrong.enrollment, "a match that is merely strong must not feed the profile")

        let veryStrong = resolver.resolve(ResolverInput(label: "B", voice: voice("sam", 0.78, .strong)))
        XCTAssertEqual(veryStrong.enrollment, .highConfidenceVoiceMatch)
    }

    func testBorderlineVoiceWithoutTranscriptEvidenceStaysUnidentified() {
        let resolution = resolver.resolve(ResolverInput(label: "B", voice: voice("sam", 0.52, .borderline)))
        XCTAssertEqual(resolution.outcome, .unidentified)
        XCTAssertEqual(resolution.state, .unidentified)
        XCTAssertNil(resolution.enrollment)
        XCTAssertEqual(resolution.evidence.map(\.applied), [false], "the near miss stays inspectable")
    }

    func testBorderlineVoiceConfirmedByTranscriptResolves() {
        let addressed = finding("B", "Sam", .medium, .addressedByName, evidence: [("u2", "Sam, was denkst du")])
        let resolution = resolver.resolve(ResolverInput(label: "B", voice: voice("sam", 0.52, .borderline), finding: addressed))
        XCTAssertEqual(resolution.outcome, .person("sam"))
        XCTAssertEqual(resolution.confidence, "medium")
        XCTAssertNil(resolution.enrollment)
    }

    func testBorderlineVoiceIsNotConfirmedByEvidenceForSomeoneElse() {
        let addressed = finding("B", "Anna", .medium, .addressedByName, evidence: [("u2", "Anna, was denkst du")])
        let resolution = resolver.resolve(ResolverInput(label: "B", voice: voice("sam", 0.52, .borderline), finding: addressed))
        XCTAssertEqual(resolution.outcome, .unidentified)
    }

    func testWeakTranscriptEvidenceAloneNeverNamesAnyone() {
        for basis in [NameFinding.Basis.addressedByName, .introducedByOther, .context] {
            let resolution = resolver.resolve(ResolverInput(label: "B", voice: nil, finding: finding("B", "Sam", .high, basis, evidence: [("u2", "Sam")])))
            XCTAssertEqual(resolution.outcome, .unidentified, "\(basis)")
        }
        let mediumSelfID = finding("B", "Sam", .medium, .selfIdentification, evidence: [("u1", "bin Sam")])
        XCTAssertEqual(resolver.resolve(ResolverInput(label: "B", finding: mediumSelfID)).outcome, .unidentified)
    }

    func testExplicitSelfIdentificationOfUnknownPersonCreatesThem() {
        let resolution = resolver.resolve(ResolverInput(label: "B", voice: voice("sam", 0.2, .unknown), finding: selfID("Robert")))
        XCTAssertEqual(resolution.outcome, .newPerson(name: "Robert"))
        XCTAssertEqual(resolution.state, .automatic)
        XCTAssertEqual(resolution.enrollment, .explicitSelfIdentification)
    }

    func testSelfIdentificationAsKnownPersonWithMismatchedVoiceDoesNotTouchTheirProfile() {
        let resolution = resolver.resolve(ResolverInput(label: "B", voice: voice("anna", 0.2, .unknown), finding: selfID("Sam")))
        XCTAssertEqual(resolution.outcome, .person("sam"))
        XCTAssertEqual(resolution.confidence, "medium")
        XCTAssertNil(resolution.enrollment)
    }

    func testSelfIdentificationBootstrapsProfileOfKnownPersonWithoutVoiceData() {
        let resolver = IdentityResolver(people: [sam], peopleWithVoiceProfile: [], thresholds: thresholds)
        let resolution = resolver.resolve(ResolverInput(label: "B", finding: selfID("sam")))
        XCTAssertEqual(resolution.outcome, .person("sam"))
        XCTAssertEqual(resolution.enrollment, .explicitSelfIdentification)
    }

    func testStrongVoiceContradictedBySelfIdentificationStaysUnidentified() {
        let resolution = resolver.resolve(ResolverInput(label: "B", voice: voice("sam", 0.8, .strong), finding: selfID("Anna")))
        XCTAssertEqual(resolution.outcome, .unidentified)
        XCTAssertFalse(resolution.evidence.contains { $0.applied })
    }

    func testAmbiguousNameDoesNotCreateOrAssign() {
        let other = Person(id: "sam2", displayName: "sam", createdAt: Date(timeIntervalSince1970: 0))
        let resolver = IdentityResolver(people: [sam, other], peopleWithVoiceProfile: [], thresholds: thresholds)
        XCTAssertEqual(resolver.resolve(ResolverInput(label: "B", finding: selfID("Sam"))).outcome, .unidentified)
    }

    func testNothingKnownIsAValidOutcome() {
        let resolution = resolver.resolve(ResolverInput(label: "C"))
        XCTAssertEqual(resolution, Resolution(outcome: .unidentified, state: .unidentified, confidence: nil, evidence: [], enrollment: nil))
    }
}
