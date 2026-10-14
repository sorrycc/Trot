import Foundation

/// Any chat completions endpoint: OpenAI, DeepSeek, Qwen, Ollama and others.
struct OpenAIService: TranslationService {
    let kind = ServiceKind.openAI
    let config: ServiceConfig

    func translate(_ text: String, from source: Language?, to target: Language) -> AsyncThrowingStream<TranslationChunk, Error> {
        let config = config
        return HTTP.stream { continuation in
            guard !config.apiKey.isEmpty else { throw TranslationError.missingKey(.openAI) }
            let body: [String: Any] = [
                "model": config.model,
                "stream": true,
                "temperature": 0.2,
                "messages": [
                    ["role": "system", "content": TranslationPrompt.system(from: source, to: target)],
                    ["role": "user", "content": text],
                ],
            ]
            let bytes = try await HTTP.post(
                config.trimmedBaseURL + "/chat/completions",
                headers: ["Authorization": "Bearer \(config.apiKey)"], body: body
            )
            do {
                // Reasoning arrives token by token; the panel needs to hear of it once.
                var saidThinking = false
                for try await sse in HTTP.events(bytes) {
                    let event = sse.json
                    if let error = event["error"] as? [String: Any] {
                        throw TranslationError.refused(error["message"] as? String ?? "")
                    }
                    guard let choices = event["choices"] as? [[String: Any]], let first = choices.first else { continue }
                    if let delta = first["delta"] as? [String: Any], let chunk = Self.chunk(in: delta),
                        chunk != .thinking || !saidThinking
                    {
                        if chunk == .thinking { saidThinking = true }
                        continuation.yield(chunk)
                    }
                    switch first["finish_reason"] as? String {
                    case "length": throw TranslationError.truncated
                    case "content_filter": throw TranslationError.refused("")
                    default: break
                    }
                }
            } catch TranslationError.notAStream(let body) {
                // A gateway that ignored `stream` sends the whole completion at once.
                guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                    let choices = json["choices"] as? [[String: Any]]
                else { throw TranslationError.notAStream(body) }
                if choices.first?["finish_reason"] as? String == "content_filter" { throw TranslationError.refused("") }
                guard let message = choices.first?["message"] as? [String: Any], let content = message["content"] as? String
                else { throw TranslationError.notAStream(body) }
                continuation.yield(.text(content))
                if choices.first?["finish_reason"] as? String == "length" { throw TranslationError.truncated }
            }
        }
    }

    /// What a streamed delta carries: text, or reasoning, which DeepSeek
    /// and Qwen send as `reasoning_content` and OpenRouter and Ollama as
    /// `reasoning`. Reasoning is never shown, only noted.
    static func chunk(in delta: [String: Any]) -> TranslationChunk? {
        if let content = delta["content"] as? String, !content.isEmpty { return .text(content) }
        for key in ["reasoning_content", "reasoning"] {
            if let reasoning = delta[key] as? String, !reasoning.isEmpty { return .thinking }
        }
        return nil
    }
}
