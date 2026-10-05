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

    /// The model in use: the one in Settings, else the default.
    @MainActor
    var activeModel: String {
        let model = Settings.model(for: self)
        return model.isEmpty ? defaultModel : model
    }

    /// The base URL in use: the one in Settings, tidied, else the default.
    @MainActor
    var activeBaseURL: String {
        let base = Settings.baseURL(for: self)
        return base.isEmpty ? defaultBaseURL : Self.normalizedBaseURL(base, for: self)
    }

    /// The host requests go to, for opening the connection ahead of them.
    @MainActor
    var host: String {
        switch self {
        case .openAI, .claude: activeBaseURL
        case .deepL: DeepLService.host(forKey: Settings.apiKey(for: self))
        case .google: GoogleService.host
        }
    }

    /// `raw` as a base URL the service's paths append to: a scheme when
    /// there is none (plain http for a machine on the desk, which rarely
    /// speaks TLS), no trailing slashes, and without the path of the
    /// endpoint itself, which is pasted along more often than not.
    static func normalizedBaseURL(_ raw: String, for kind: ServiceKind) -> String {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return url }
        if !url.contains("://") {
            let host = url.split(separator: "/", maxSplits: 1).first.map(String.init) ?? url
            url = (isLocal(host: host) ? "http://" : "https://") + url
        }
        while url.hasSuffix("/") { url.removeLast() }
        let endpoints: [String] =
            switch kind {
            case .openAI: ["/chat/completions"]
            case .claude: ["/v1/messages", "/v1"]
            case .deepL, .google: []
            }
        for endpoint in endpoints where url.hasSuffix(endpoint) {
            url.removeLast(endpoint.count)
            break
        }
        return url
    }

    /// Loopback and link-local names, with or without a port.
    private static func isLocal(host: String) -> Bool {
        var name = host.lowercased()
        if name.hasPrefix("[") { return name.hasPrefix("[::1]") }
        if let colon = name.lastIndex(of: ":") { name = String(name[..<colon]) }
        return name == "localhost" || name.hasPrefix("127.") || name == "0.0.0.0" || name.hasSuffix(".local")
    }

    /// The service with its current settings. Cheap, so callers make one per request.
    @MainActor
    func makeService() -> any TranslationService {
        let config = ServiceConfig(baseURL: activeBaseURL, apiKey: Settings.apiKey(for: self), model: activeModel)
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
        case .badURL(let url): return "\"\(url)\" is not a valid URL. Check the base URL in Settings."
        case .http(let code, let message): return message.isEmpty ? Self.describe(status: code) : "HTTP \(code): \(message)"
        case .invalidResponse: return "The service sent a reply Trot can't read."
        case .refused(let reason): return reason.isEmpty ? "The service declined to translate this." : reason
        case .truncated: return "The translation was cut off: the text is too long for one request. Try a shorter selection."
        case .notAStream(let body):
            let message = HTTP.errorMessage(in: body)
            return message.isEmpty ? "The service replied with something other than a translation. Check the base URL." : message
        }
    }

    /// A sentence for a status code that came with no message of its own.
    static func describe(status code: Int) -> String {
        switch code {
        case 401, 403: return "The API key was rejected (HTTP \(code))."
        case 404: return "Not found (HTTP 404). Check the base URL and the model."
        case 413: return "The text is too long for this service (HTTP 413)."
        case 429: return "Too many requests (HTTP 429). Try again in a moment."
        case 456: return "The DeepL quota for this key is used up (HTTP 456)."
        case 500...599: return "The service is having trouble (HTTP \(code)). Try again in a moment."
        default: return "HTTP \(code)"
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

    /// Opens the connection to `kind`'s host ahead of the request, so the
    /// DNS, TCP and TLS round trips overlap with reading the selection
    /// instead of adding to the wait for the first word. The reply is
    /// ignored; the pooled connection is what matters.
    @MainActor
    static func preconnect(to kind: ServiceKind) {
        guard let url = URL(string: kind.host), url.host() != nil else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        session.dataTask(with: request).resume()
    }

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
                    // Kept only until the first event shows this is a stream.
                    var other = ""
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else {
                            if !sawEvent, other.utf8.count < 64 * 1024 {
                                other += line
                                other += "\n"
                            }
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
