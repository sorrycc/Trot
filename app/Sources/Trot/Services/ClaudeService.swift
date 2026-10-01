import Foundation

/// The Anthropic Messages API, streamed. Raw HTTP, since there is no Swift SDK.
struct ClaudeService: TranslationService {
    let kind = ServiceKind.claude
    let config: ServiceConfig

    func translate(_ text: String, from source: Language?, to target: Language) -> AsyncThrowingStream<String, Error> {
        let config = config
        return HTTP.stream { continuation in
            guard !config.apiKey.isEmpty else { throw TranslationError.missingKey(.claude) }
            var body: [String: Any] = [
                "model": config.model,
                "max_tokens": 16000,
                "stream": true,
                "system": TranslationPrompt.system(from: source, to: target),
                "messages": [["role": "user", "content": text]],
            ]
            var headers = [
                "x-api-key": config.apiKey,
                "anthropic-version": "2023-06-01",
            ]
            // Claude 5 models think by default; translation needs little of
            // it, and low effort keeps the first token quick. A safety decline
            // on these models reruns the request on a fallback model.
            if Self.isClaude5(config.model) {
                body["output_config"] = ["effort": "low"]
                body["fallbacks"] = "default"
                headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
            }
            let bytes = try await HTTP.post(config.trimmedBaseURL + "/v1/messages", headers: headers, body: body)
            do {
                try await Self.readEvents(bytes, into: continuation)
            } catch TranslationError.notAStream(let body) {
                // A proxy that ignored `stream` sends the whole message at once.
                guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                    let content = json["content"] as? [[String: Any]],
                    let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
                else { throw TranslationError.notAStream(body) }
                continuation.yield(text)
                if json["stop_reason"] as? String == "max_tokens" { throw TranslationError.truncated }
            }
        }
    }

    private static func readEvents(_ bytes: URLSession.AsyncBytes, into continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
            for try await sse in HTTP.events(bytes) {
                let event = sse.json
                switch event["type"] as? String {
                case "content_block_delta":
                    guard let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                        let piece = delta["text"] as? String
                    else { continue }
                    continuation.yield(piece)
                case "message_delta":
                    let delta = event["delta"] as? [String: Any]
                    switch delta?["stop_reason"] as? String {
                    case "refusal":
                        let details = event["stop_details"] as? [String: Any]
                        throw TranslationError.refused(details?["explanation"] as? String ?? "")
                    case "max_tokens", "model_context_window_exceeded":
                        throw TranslationError.truncated
                    default:
                        break
                    }
                case "error":
                    let error = event["error"] as? [String: Any]
                    throw TranslationError.refused(error?["message"] as? String ?? "")
                default:
                    continue
                }
            }
    }

    private static func isClaude5(_ model: String) -> Bool {
        ["claude-opus-5", "claude-sonnet-5", "claude-fable-5", "claude-mythos-5"].contains { model.hasPrefix($0) }
    }
}
