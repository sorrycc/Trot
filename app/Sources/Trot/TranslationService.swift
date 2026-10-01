import Foundation

/// Where translations come from. One is active at a time, see `Settings.service`.
enum ServiceKind: String, CaseIterable, Codable, Sendable {
    case openAI
    case claude
    case deepL
    case google

    var displayName: String {
        switch self {
        case .openAI: "OpenAI Compatible"
        case .claude: "Claude"
        case .deepL: "DeepL"
        case .google: "Google"
        }
    }

    /// The short name in the panel's footer.
    var shortName: String {
        switch self {
        case .openAI: "OpenAI"
        case .claude: "Claude"
        case .deepL: "DeepL"
        case .google: "Google"
        }
    }

    var needsKey: Bool { self != .google }

    /// Where the service hands out keys, for a link under the key field.
    var keyPage: String? {
        switch self {
        case .openAI: "https://platform.openai.com/api-keys"
        case .claude: "https://console.anthropic.com/settings/keys"
        case .deepL: "https://www.deepl.com/your-account/keys"
        case .google: nil
        }
    }
    var hasBaseURL: Bool { self == .openAI || self == .claude }
    var hasModel: Bool { self == .openAI || self == .claude }

    var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .claude: "https://api.anthropic.com"
        case .deepL, .google: ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: "gpt-4o-mini"
        case .claude: "claude-opus-5-5"
        case .deepL, .google: ""
        }
    }

    /// The service with its current settings. Cheap, so callers make one per request.
    @MainActor
    func makeService() -> any TranslationService {
        let base = Settings.baseURL(for: self)
        let config = ServiceConfig(
            baseURL: base.isEmpty ? defaultBaseURL : base,
            apiKey: Settings.apiKey(for: self),
            model: Settings.model(for: self).isEmpty ? defaultModel : Settings.model(for: self)
        )
        switch self {
        case .openAI: return OpenAIService(config: config)
        case .claude: return ClaudeService(config: config)
        case .deepL: return DeepLService(config: config)
        case .google: return GoogleService()
        }
    }
}

struct ServiceConfig: Sendable {
    var baseURL: String
    var apiKey: String
    var model: String

    /// `baseURL` without a trailing slash, so paths append cleanly.
    var trimmedBaseURL: String {
        baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    }
}

/// A translation arrives as a stream of text pieces. Services without
/// streaming yield the whole translation once.
protocol TranslationService: Sendable {
    var kind: ServiceKind { get }
    func translate(_ text: String, from source: Language?, to target: Language) -> AsyncThrowingStream<String, Error>
}

enum TranslationError: LocalizedError {
    case missingKey(ServiceKind)
    case badURL(String)
    case http(Int, String)
    case invalidResponse
    case refused(String)
    /// A 200 reply that wasn't an event stream, with its body.
    case notAStream(Data)
    /// The service stopped at its output limit before the end of the text.
    case truncated

    var errorDescription: String? {
        switch self {
        case .missingKey(let kind): return "\(kind.displayName) needs an API key."
        case .badURL(let url): return "\"\(url)\" is not a valid URL."
        case .http(let code, let message): return message.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(message)"
        case .invalidResponse: return "The service sent a reply Trot can't read."
        case .refused(let reason): return reason.isEmpty ? "The service declined to translate this." : reason
        case .truncated: return "The translation was cut off: the text is too long for one request. Try a shorter selection."
        case .notAStream(let body):
            let message = HTTP.errorMessage(in: body)
            return message.isEmpty ? "The service replied with something other than a translation. Check the base URL." : message
        }
    }
}

/// Shared pieces for the HTTP services.
enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // The request timeout resets on every byte, and keep-alive pings
        // count, so the resource timeout caps the whole transfer.
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Posts `body` as JSON and returns the response bytes, or throws with
    /// the service's error message for a non-2xx status.
    static func post(_ url: String, headers: [String: String], body: [String: Any]) async throws -> URLSession.AsyncBytes {
        try await post(url, headers: headers, body: try JSONSerialization.data(withJSONObject: body), contentType: "application/json")
    }

    static func post(_ url: String, headers: [String: String], body: Data, contentType: String) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await session.bytes(for: request(url, headers: headers, body: body, contentType: contentType))
        try await check(response, bytes)
        return bytes
    }

    private static func request(_ url: String, headers: [String: String], body: Data, contentType: String) throws -> URLRequest {
        guard let target = URL(string: url), target.scheme != nil, target.host() != nil else { throw TranslationError.badURL(url) }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        return request
    }

    /// `fields` as a form body, with every reserved character escaped, so a
    /// "+" in the text stays a plus.
    static func formBody(_ fields: [(String, String)]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = fields.map { name, value in
            name + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
        }
        return Data(encoded.joined(separator: "&").utf8)
    }

    /// Posts `body` and returns the whole reply at once, for services that
    /// answer with one JSON document. Reading the reply as a block is far
    /// cheaper than iterating it byte by byte.
    static func postForData(_ url: String, headers: [String: String], body: [String: Any]) async throws -> Data {
        try await postForData(url, headers: headers, body: try JSONSerialization.data(withJSONObject: body), contentType: "application/json")
    }

    static func postForData(_ url: String, headers: [String: String], body: Data, contentType: String) async throws -> Data {
        let (data, response) = try await session.data(for: request(url, headers: headers, body: body, contentType: contentType))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TranslationError.http(http.statusCode, errorMessage(in: data))
        }
        return data
    }

    private static func check(_ response: URLResponse, _ bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        var data = Data()
        for try await byte in bytes.prefix(16 * 1024) { data.append(byte) }
        throw TranslationError.http(http.statusCode, errorMessage(in: data))
    }

    /// The message in a JSON error body, in the shapes OpenAI, Anthropic and
    /// DeepL use, else the body itself when it's short plain text. Markup,
    /// as a wrong base URL answers with, is never a message.
    static func errorMessage(in data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let message = json["message"] as? String { return message }
            if let error = json["error"] as? String { return error }
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 200, !text.hasPrefix("<"), !text.hasPrefix("{") else { return "" }
        return text
    }

    /// The `data:` payloads of a server-sent event stream. Stops at `[DONE]`.
    /// A reply with no events at all, such as plain JSON from a gateway that
    /// ignores `stream`, ends with `TranslationError.notAStream` and the body.
    static func events(_ bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var sawEvent = false
                    var other = ""
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else {
                            if other.count < 64 * 1024 { other += line + "\n" }
                            continue
                        }
                        sawEvent = true
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        continuation.yield(SSEEvent(data: Data(payload.utf8)))
                    }
                    if sawEvent {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: TranslationError.notAStream(Data(other.utf8)))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A stream that runs `work` in a task cancelled with the stream.
    static func stream(_ work: @escaping @Sendable (AsyncThrowingStream<String, Error>.Continuation) async throws -> Void)
        -> AsyncThrowingStream<String, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await work(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// One server-sent event's payload.
struct SSEEvent: Sendable {
    let data: Data

    /// The payload as a JSON object, or empty when it isn't one.
    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

/// The instructions the LLM services share.
enum TranslationPrompt {
    static func system(from source: Language?, to target: Language) -> String {
        let from = source.map { "from \($0.englishName) " } ?? ""
        return """
            You are a translation engine. Translate the text the user sends \(from)into \(target.englishName).
            Reply with the translation only: no explanations, no notes, no quotation marks around it.
            Keep the line breaks, lists and inline formatting of the original.
            If the text is already in \(target.englishName), return it unchanged.
            Technical terms, code, product names and URLs stay as they are.
            """
    }
}
