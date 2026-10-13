import Foundation

// MARK: - Wire models (https://www.assemblyai.com/docs/api-reference)

struct AssemblyAITranscriptRequest: Encodable, Equatable {
    var audioURL: String
    var speechModels: [String]
    var speakerLabels = true
    /// The languages spoken in the recording; Universal-3.5 Pro code-switches between them.
    /// Mutually exclusive with `language_code` and `language_detection` (the API rejects the
    /// combination), so neither of those, nor `language_detection_options`, is sent.
    /// Trade-off: `on_no_speech_detected: fallback` lives under language detection and is therefore
    /// unavailable, so a recording without any speech may come back as a failed job rather than an
    /// empty transcript. Not verified against the live API.
    var languageCodes: [String]
    var prompt: String?

    enum CodingKeys: String, CodingKey {
        case audioURL = "audio_url", speechModels = "speech_models", speakerLabels = "speaker_labels"
        case languageCodes = "language_codes", prompt
    }
}

struct AssemblyAITranscript: Decodable {
    enum Status: String, Decodable { case queued, processing, completed, error }

    struct Word: Decodable {
        var text: String
        var start: Int
        var end: Int
        var confidence: Double
        var speaker: String?
    }

    struct Utterance: Decodable {
        var speaker: String
        var start: Int
        var end: Int
        var text: String
        var confidence: Double
    }

    var id: String
    var status: Status
    var error: String?
    var utterances: [Utterance]?
    var words: [Word]?
    var languageCode: String?
    var speechModelUsed: String?

    enum CodingKeys: String, CodingKey {
        case id, status, error, utterances, words
        case languageCode = "language_code", speechModelUsed = "speech_model_used"
    }
}

/// Only the fields needed while a job is still running (the full response can be very large).
private struct AssemblyAIStatus: Decodable {
    var id: String
    var status: AssemblyAITranscript.Status
    var error: String?
}

private struct AssemblyAIUpload: Decodable {
    var uploadURL: String
    enum CodingKeys: String, CodingKey { case uploadURL = "upload_url" }
}

private struct AssemblyAIErrorBody: Decodable { var error: String }

/// Result of polling: still running, or the finished job's raw response bytes.
enum AssemblyAIPollResult {
    case pending(AssemblyAITranscript.Status)
    case completed(rawResponse: Data)
}

// MARK: - Client

/// Network boundary to AssemblyAI. The only thing sent is the merged audio (plus request options).
/// Pre-recorded API: POST /v2/upload → POST /v2/transcript → GET /v2/transcript/{id}.
struct AssemblyAIClient {
    static let serviceName = "AssemblyAI"

    var baseURL = AppConfig.AssemblyAI.baseURL
    var session: URLSession = .shared
    var apiKey: () -> String?

    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        guard let key = apiKey(), !key.isEmpty else {
            throw ServiceError(service: Self.serviceName, kind: .missingKey)
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ perform: () async throws -> (Data, URLResponse)) async throws -> Data {
        do {
            let (data, response) = try await perform()
            return try HTTP.validate(data, response, service: Self.serviceName) {
                (try? JSONDecoder().decode(AssemblyAIErrorBody.self, from: $0))?.error
            }
        } catch {
            throw HTTP.transportError(error, service: Self.serviceName)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch {
            throw ServiceError(service: Self.serviceName, kind: .invalidResponse, detail: "\(type)")
        }
    }

    /// Streams the file from disk; `progress` reports the fraction of bytes sent.
    func upload(file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        var request = try request("v2/upload", method: "POST")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let delegate = UploadProgress(progress)
        let data = try await send { try await session.upload(for: request, fromFile: file, delegate: delegate) }
        return try decode(AssemblyAIUpload.self, from: data).uploadURL
    }

    /// Creates the transcription job and returns its transcript ID.
    func createTranscript(_ body: AssemblyAITranscriptRequest) async throws -> String {
        var request = try request("v2/transcript", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let data = try await send { try await session.data(for: request) }
        return try decode(AssemblyAIStatus.self, from: data).id
    }

    func poll(transcriptID: String) async throws -> AssemblyAIPollResult {
        let request = try request("v2/transcript/\(transcriptID)")
        let data = try await send { try await session.data(for: request) }
        let status = try decode(AssemblyAIStatus.self, from: data)
        switch status.status {
        case .completed:
            return .completed(rawResponse: data)
        case .error:
            throw ServiceError(service: Self.serviceName, kind: .jobFailed, detail: status.error)
        case .queued, .processing:
            return .pending(status.status)
        }
    }

    /// Cheap authenticated call for the Settings "Test" button (lists at most one transcript).
    func verifyKey() async throws {
        var request = try request("v2/transcript")
        request.url?.append(queryItems: [URLQueryItem(name: "limit", value: "1")])
        _ = try await send { try await session.data(for: request) }
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
