import XCTest
@testable import MicIngest

/// A finished AssemblyAI response as returned by GET /v2/transcript/{id} (trimmed to the fields that matter).
let sampleAssemblyAIResponse = """
{
  "id": "5f1c0e2a-7d3b-4a55-9c0e-111111111111",
  "status": "completed",
  "audio_url": "https://cdn.assemblyai.com/upload/abc",
  "audio_duration": 7698,
  "language_code": "de",
  "speech_model_used": "universal-3-5-pro",
  "speech_models": ["universal-3-5-pro"],
  "confidence": 0.93,
  "text": "Ich glaube, wir sollten morgen früher losfahren. Ja, denke ich auch. Hi, ich bin Sam.",
  "words": [
    {"text": "Ich", "start": 14000, "end": 14200, "confidence": 0.99, "speaker": "A"},
    {"text": "glaube,", "start": 14210, "end": 14600, "confidence": 0.98, "speaker": "A"}
  ],
  "utterances": [
    {"speaker": "A", "start": 14000, "end": 19500, "confidence": 0.97,
     "text": "Ich glaube, wir sollten morgen früher losfahren.",
     "words": [{"text": "Ich", "start": 14000, "end": 14200, "confidence": 0.99, "speaker": "A"}]},
    {"speaker": "B", "start": 22000, "end": 24100, "confidence": 0.91, "text": "Ja, denke ich auch.", "words": []},
    {"speaker": "C", "start": 123000, "end": 127400, "confidence": 0.88, "text": "Hi, ich bin Sam.", "words": []},
    {"speaker": "A", "start": 3600000, "end": 3604000, "confidence": 0.95, "text": "Okay, weiter geht's.", "words": []}
  ],
  "some_future_field": {"nested": true}
}
"""

func sampleMetadata(speakers: [SpeakerEntry] = []) -> SessionMetadata {
    let start = date("2026-10-01 20:43:49")
    return SessionMetadata(
        app: .init(name: "MicIngest", version: "1.0"),
        session: .init(id: "TX01-2026-10-01_20-43-49-abcd1234", fingerprint: "abcd1234ffff", start: start,
                       end: start.addingTimeInterval(7698), timeZone: "Europe/Berlin", durationSeconds: 7698, transmitter: "TX01"),
        sources: [
            .init(filename: "TX01_MIC002_20261001_204349_orig.wav", start: start, durationSeconds: 1800.6,
                  frameCount: 86_428_800, fileSizeBytes: 259_286_444, offsetSeconds: 0),
            .init(filename: "TX01_MIC003_20261001_211350_orig.wav", start: date("2026-10-01 21:13:50"), durationSeconds: 5897.4,
                  frameCount: 283_075_200, fileSizeBytes: 849_225_644, offsetSeconds: 1800.6),
        ],
        audio: .init(filename: "2026-10-01_20-43-49.flac", container: .flac, sampleRate: 48_000, channels: 1, bitDepth: 24,
                     isFloat: false, frameCount: 369_504_000, pcmSHA256: "00ff"),
        transcription: .init(transcriptID: "5f1c0e2a", requestedModels: ["universal-3-5-pro"], modelUsed: "universal-3-5-pro",
                             languageCodes: ["de", "en"], languageDetected: "de", prompt: "context",
                             submittedAt: date("2026-10-02 09:00:00"), completedAt: date("2026-10-02 09:04:10"),
                             rawResponseFilename: "2026-10-01_20-43-49.assemblyai.json"),
        speakers: speakers,
        identityInference: .init(
            llm: .init(model: "openai/gpt-oss-120b", status: "ok", error: nil),
            voice: .init(model: "WeSpeaker ResNet34-LM", version: "v1", dimension: 256, status: "ok", error: nil, thresholds: .default)),
        processing: .init(stage: "complete", processedAt: date("2026-10-02 09:05:00"), warnings: []))
}

func speakerEntry(_ label: String, name: String? = nil, personID: String? = nil, state: IdentityState = .unidentified,
                  evidence: [IdentityEvidence] = []) -> SpeakerEntry {
    SpeakerEntry(label: label, personID: personID, displayName: name ?? SpeakerEntry.defaultName(label), state: state,
                 confidence: nil, evidence: evidence, utteranceCount: 1, speechSeconds: 5)
}

final class AssemblyAIDecodingTests: XCTestCase {
    func testDecodesCompletedResponse() throws {
        let transcript = try Transcript(rawResponse: Data(sampleAssemblyAIResponse.utf8))
        XCTAssertEqual(transcript.id, "5f1c0e2a-7d3b-4a55-9c0e-111111111111")
        XCTAssertEqual(transcript.modelUsed, "universal-3-5-pro")
        XCTAssertEqual(transcript.languageCode, "de")
        XCTAssertEqual(transcript.utterances.count, 4)
        XCTAssertEqual(transcript.speakers, ["A", "B", "C"])
        XCTAssertEqual(transcript.utterances[2], TranscriptUtterance(
            index: 2, speaker: "C", startMs: 123_000, endMs: 127_400, text: "Hi, ich bin Sam.", confidence: 0.88))
        XCTAssertEqual(transcript.speechSeconds(of: "A"), 9.5, accuracy: 0.001)
    }

    func testFallsBackToWordsWhenUtterancesAreMissing() throws {
        let json = """
        {"id": "x", "status": "completed", "utterances": null, "words": [
          {"text": "Hallo", "start": 0, "end": 400, "confidence": 0.9, "speaker": null},
          {"text": "zusammen.", "start": 450, "end": 900, "confidence": 0.8, "speaker": null},
          {"text": "Später.", "start": 9000, "end": 9500, "confidence": 0.7, "speaker": null}]}
        """
        let transcript = try Transcript(rawResponse: Data(json.utf8))
        XCTAssertEqual(transcript.utterances.map(\.text), ["Hallo zusammen.", "Später."])
        XCTAssertEqual(transcript.speakers, ["A"])
    }

    func testEmptyTranscriptIsValid() throws {
        let transcript = try Transcript(rawResponse: Data(#"{"id": "x", "status": "completed", "text": "", "utterances": null, "words": []}"#.utf8))
        XCTAssertTrue(transcript.utterances.isEmpty)
        XCTAssertTrue(transcript.speakers.isEmpty)
    }

    func testRequestUsesDocumentedParameterNames() throws {
        let request = AssemblyAITranscriptRequest(audioURL: "https://cdn/upload/1", speechModels: AppConfig.AssemblyAI.speechModels,
                                                  languageCodes: ["de", "en"], prompt: "ctx")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(json["audio_url"] as? String, "https://cdn/upload/1")
        XCTAssertEqual(json["speech_models"] as? [String], ["universal-3-5-pro"])
        XCTAssertEqual(json["speaker_labels"] as? Bool, true)
        XCTAssertEqual(json["language_codes"] as? [String], ["de", "en"])
        // AssemblyAI rejects `language_codes` together with any of these.
        XCTAssertNil(json["language_detection"])
        XCTAssertNil(json["language_detection_options"])
        XCTAssertNil(json["language_code"])
        XCTAssertEqual(json["prompt"] as? String, "ctx")
        XCTAssertNil(json["speakers_expected"], "the number of speakers is never guessed")
        XCTAssertNil(json["speaker_options"])
        XCTAssertEqual(Set(json.keys), ["audio_url", "speech_models", "speaker_labels", "language_codes", "prompt"])
    }

    func testPromptIsOmittedWhenEmpty() throws {
        let request = AssemblyAITranscriptRequest(audioURL: "u", speechModels: ["m"], languageCodes: ["de", "en"], prompt: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertNil(json["prompt"])
    }
}

final class TimelineAndMarkdownTests: XCTestCase {
    func testWallClockConversion() {
        let timeline = sampleMetadata().timeline
        XCTAssertEqual(timeline.clockTime(atMs: 0), "20:43:49")
        XCTAssertEqual(timeline.clockTime(atMs: 14_000), "20:44:03")
        // Inside the second chunk, time continues from that chunk's own start timestamp.
        XCTAssertEqual(timeline.clockTime(atMs: 1_800_600), "21:13:50")
        XCTAssertEqual(timeline.clockTime(atMs: 3_600_000), "21:43:49")
    }

    func testWallClockCrossesMidnight() {
        let timeline = SessionTimeline(chunks: [.init(offsetSeconds: 0, start: date("2026-10-01 23:34:14")),
                                                .init(offsetSeconds: 1800, start: date("2026-10-02 00:04:14"))], timeZone: berlin)
        XCTAssertEqual(timeline.clockTime(atMs: 1_799_000), "00:04:13")
        XCTAssertEqual(timeline.clockTime(atMs: 1_860_000), "00:05:14")
        XCTAssertEqual(timeline.date(atMs: 1_860_000), date("2026-10-02 00:05:14"))
    }

    func testManuallyMergedSessionWithGapKeepsRealClockTimes() {
        // Two takes merged by hand, 10 minutes apart: the second take must not inherit the first take's clock.
        let timeline = SessionTimeline(chunks: [.init(offsetSeconds: 0, start: date("2026-10-01 10:00:00")),
                                                .init(offsetSeconds: 60, start: date("2026-10-01 10:11:00"))], timeZone: berlin)
        XCTAssertEqual(timeline.clockTime(atMs: 59_000), "10:00:59")
        XCTAssertEqual(timeline.clockTime(atMs: 61_000), "10:11:01")
    }

    func testClockUsesTheSessionTimeZoneNotTheSystemOne() {
        let timeline = SessionTimeline(chunks: [.init(offsetSeconds: 0, start: date("2026-10-01 20:43:49"))],
                                       timeZone: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(timeline.clockTime(atMs: 0), "14:43:49")
    }

    func testMarkdownRendering() throws {
        let transcript = try Transcript(rawResponse: Data(sampleAssemblyAIResponse.utf8))
        let metadata = sampleMetadata(speakers: [
            speakerEntry("A", name: "Alex", personID: "p1", state: .manual),
            speakerEntry("B"),
            speakerEntry("C", name: "Sam", personID: "p2", state: .automatic),
        ])
        let expected = """
        ---
        date: 2026-10-01
        start: "20:43:49"
        end: "22:52:07"
        duration: 2h 08m
        speakers: [Alex, Speaker B, Sam]
        audio: Data/2026-10-01_20-43-49.flac
        ---

        # Recording · 1 October 2026

        ## 20:44:03 · Alex

        Ich glaube, wir sollten morgen früher losfahren.

        ## 20:44:11 · Speaker B

        Ja, denke ich auch.

        ## 20:45:52 · Sam

        Hi, ich bin Sam.

        ## 21:43:49 · Alex

        Okay, weiter geht's.

        """
        XCTAssertEqual(MarkdownRenderer.render(transcript: transcript, metadata: metadata), expected)
        // Deterministic: rendering twice gives identical output.
        XCTAssertEqual(MarkdownRenderer.render(transcript: transcript, metadata: metadata),
                       MarkdownRenderer.render(transcript: transcript, metadata: metadata))
    }

    func testMarkdownChangesWhenSpeakerMappingChangesWithoutRetranscribing() throws {
        let transcript = try Transcript(rawResponse: Data(sampleAssemblyAIResponse.utf8))
        let before = MarkdownRenderer.render(transcript: transcript, metadata: sampleMetadata(speakers: [speakerEntry("B")]))
        let after = MarkdownRenderer.render(transcript: transcript, metadata: sampleMetadata(speakers: [
            speakerEntry("B", name: "Robert", personID: "p3", state: .manual)]))
        XCTAssertTrue(before.contains("## 20:44:11 · Speaker B"))
        XCTAssertTrue(after.contains("## 20:44:11 · Robert"))
        XCTAssertFalse(after.contains("Speaker B"))
    }

    func testFrontMatterQuotesNamesThatNeedItAndListsEachPersonOnce() throws {
        let transcript = try Transcript(rawResponse: Data(sampleAssemblyAIResponse.utf8))
        // Two diarized clusters resolved to the same person, and a name with YAML-significant characters.
        let markdown = MarkdownRenderer.render(transcript: transcript, metadata: sampleMetadata(speakers: [
            speakerEntry("A", name: "Müller, Anna: \"Chefin\"", personID: "p1", state: .manual),
            speakerEntry("B", name: "Jörg", personID: "p2", state: .manual),
            speakerEntry("C", name: "Jörg", personID: "p2", state: .automatic),
        ]))
        XCTAssertTrue(markdown.contains(#"speakers: ["Müller, Anna: \"Chefin\"", Jörg]"# + "\n"), markdown)
    }

    func testMarkdownNotesEndDateAcrossMidnightAndEmptyTranscripts() {
        var metadata = sampleMetadata()
        metadata.session.start = date("2026-10-01 23:34:14")
        metadata.session.end = date("2026-10-02 00:28:07")
        metadata.sources = [.init(filename: "a.wav", start: metadata.session.start, durationSeconds: 3233, frameCount: 1,
                                  fileSizeBytes: 1, offsetSeconds: 0)]
        let markdown = MarkdownRenderer.render(transcript: Transcript(id: "x", utterances: []), metadata: metadata)
        XCTAssertTrue(markdown.contains("date: 2026-10-01\nstart: \"23:34:14\"\nend: \"00:28:07\"\nend_date: 2026-10-02\n"), markdown)
        XCTAssertTrue(markdown.contains("speakers: []\n"))
        XCTAssertTrue(markdown.contains("_No speech was detected in this recording._"))
    }
}

final class MetadataTests: XCTestCase {
    func testJSONRoundTrip() throws {
        let original = sampleMetadata(speakers: [
            speakerEntry("A", name: "Alex", personID: "p1", state: .manual,
                         evidence: [IdentityEvidence(source: .manual, applied: true, personID: "p1")]),
            speakerEntry("C", name: "Sam", personID: "p2", state: .automatic, evidence: [
                IdentityEvidence(source: .voiceMatch, applied: true, personID: "p2", similarity: 0.71, band: "strong"),
                IdentityEvidence(source: .selfIdentification, applied: true, personID: "p2", name: "Sam", confidence: "high",
                                 utteranceIndex: 2, timestampMs: 123_000, quote: "ich bin Sam", reason: "Introduced themselves."),
            ]),
        ])
        let data = try original.encoded()
        let decoded = try SessionMetadata.decode(data)
        XCTAssertEqual(try decoded.encoded(), data, "decode → encode must reproduce the file byte for byte")
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.speakers, original.speakers)
        XCTAssertEqual(decoded.sources, original.sources)
        XCTAssertEqual(decoded.session.start, original.session.start)
        XCTAssertEqual(decoded.transcription?.transcriptID, "5f1c0e2a")
    }

    func testDatesCarryTheLocalUTCOffset() throws {
        let json = String(decoding: try sampleMetadata().encoded(), as: UTF8.self)
        XCTAssertTrue(json.contains(#""start" : "2026-10-01T20:43:49.000+02:00""#), json)
        XCTAssertTrue(json.contains(#""timeZone" : "Europe/Berlin""#))
        XCTAssertTrue(json.contains(#""schemaVersion" : 1"#))
    }

    func testMetadataNeverContainsCredentialFields() throws {
        let json = String(decoding: try sampleMetadata().encoded(), as: UTF8.self).lowercased()
        for forbidden in ["api_key", "apikey", "authorization", "bearer", "secret", "token\""] {
            XCTAssertFalse(json.contains(forbidden), forbidden)
        }
    }
}
