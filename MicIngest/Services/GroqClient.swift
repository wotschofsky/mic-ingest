import Foundation

/// Minimal JSON value, used to describe JSON Schemas in requests.
indirect enum JSONValue: Encodable, Equatable, ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
                         ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    case string(String), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
    init(nilLiteral: ()) { self = .null }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private struct GroqChatRequest: Encodable {
    struct Message: Encodable { var role: String; var content: String }
    struct ResponseFormat: Encodable {
        struct Schema: Encodable { var name: String; var strict = true; var schema: JSONValue }
        var type = "json_schema"
        var jsonSchema: Schema
        enum CodingKeys: String, CodingKey { case type, jsonSchema = "json_schema" }
    }

    var model: String
    var messages: [Message]
    var temperature = 0.0
    var responseFormat: ResponseFormat
    enum CodingKeys: String, CodingKey { case model, messages, temperature, responseFormat = "response_format" }
}

private struct GroqChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { var content: String? }
        var message: Message
    }
    var choices: [Choice]
}

private struct GroqErrorBody: Decodable {
    struct Detail: Decodable { var message: String }
    var error: Detail
}

/// Network boundary to Groq. Receives transcript text only: never audio, never voice embeddings.
struct GroqClient {
    static let serviceName = "Groq"

    var baseURL = AppConfig.Groq.baseURL
    var session: URLSession = .shared
    var apiKey: () -> String?

    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        guard let key = apiKey(), !key.isEmpty else {
            throw ServiceError(service: Self.serviceName, kind: .missingKey)
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            return try HTTP.validate(data, response, service: Self.serviceName) {
                (try? JSONDecoder().decode(GroqErrorBody.self, from: $0))?.error.message
            }
        } catch {
            throw HTTP.transportError(error, service: Self.serviceName)
        }
    }

    /// Chat completion constrained to `schema` (strict structured output). Returns the JSON document.
    func structuredCompletion(model: String, system: String, user: String,
                              schemaName: String, schema: JSONValue) async throws -> Data {
        var request = try request("chat/completions", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(GroqChatRequest(
            model: model,
            messages: [.init(role: "system", content: system), .init(role: "user", content: user)],
            responseFormat: .init(jsonSchema: .init(name: schemaName, schema: schema))))
        let data = try await send(request)
        guard let response = try? JSONDecoder().decode(GroqChatResponse.self, from: data),
              let content = response.choices.first?.message.content else {
            throw ServiceError(service: Self.serviceName, kind: .invalidResponse, detail: "no message content")
        }
        return Data(content.utf8)
    }

    /// Cheap authenticated call for the Settings "Test" button.
    func verifyKey() async throws {
        _ = try await send(try request("models"))
    }
}
