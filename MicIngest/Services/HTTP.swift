import Foundation

/// Failure of a call to an external service. Messages never contain credentials or request bodies.
struct ServiceError: LocalizedError {
    enum Kind { case missingKey, unauthorized, rateLimited, server, rejected, jobFailed, transport, invalidResponse }

    var service: String
    var kind: Kind
    var statusCode: Int?
    var detail: String?
    var retryAfter: TimeInterval?

    /// Worth trying again later without changing anything.
    var isTransient: Bool { kind == .rateLimited || kind == .server || kind == .transport }

    var errorDescription: String? {
        switch kind {
        case .missingKey: "\(service) API key is missing. Add it in Settings."
        case .unauthorized: "\(service) rejected the API key. Check it in Settings."
        case .rateLimited: "\(service) is rate limiting requests. Try again in a moment."
        case .server: "\(service) is temporarily unavailable (HTTP \(statusCode ?? 0)). Retry."
        case .rejected: "\(service) rejected the request\(detail.map { ": \($0)" } ?? " (HTTP \(statusCode ?? 0)).")"
        case .jobFailed: "Transcription failed\(detail.map { " (\($0))" } ?? ""). Retry."
        case .transport: "Could not reach \(service)\(detail.map { ": \($0)" } ?? "."). Check the network connection and retry."
        case .invalidResponse: "\(service) returned a response the app could not read\(detail.map { ": \($0)" } ?? ".")"
        }
    }
}

enum HTTP {
    /// Maps a response to data or a `ServiceError`. `errorMessage` extracts the provider's own message.
    static func validate(_ data: Data, _ response: URLResponse, service: String,
                         errorMessage: (Data) -> String?) throws -> Data {
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError(service: service, kind: .invalidResponse)
        }
        Log.network.info("\(service, privacy: .public) \(http.url?.path ?? "", privacy: .public) → HTTP \(http.statusCode)")
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw ServiceError(service: service, kind: .unauthorized, statusCode: http.statusCode)
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ServiceError(service: service, kind: .rateLimited, statusCode: 429, retryAfter: retryAfter)
        case 500...:
            throw ServiceError(service: service, kind: .server, statusCode: http.statusCode)
        default:
            throw ServiceError(service: service, kind: .rejected, statusCode: http.statusCode, detail: errorMessage(data))
        }
    }

    static func transportError(_ error: Error, service: String) -> Error {
        if error is ServiceError || error is CancellationError { return error }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return CancellationError() }
            return ServiceError(service: service, kind: .transport, detail: urlError.localizedDescription)
        }
        return error
    }
}
