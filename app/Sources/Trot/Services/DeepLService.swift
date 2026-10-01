import Foundation

/// DeepL's REST API. Free keys end in `:fx` and go to the free host.
struct DeepLService: TranslationService {
    let kind = ServiceKind.deepL
    let config: ServiceConfig

    func translate(_ text: String, from source: Language?, to target: Language) -> AsyncThrowingStream<String, Error> {
        let config = config
        return HTTP.stream { continuation in
            guard !config.apiKey.isEmpty else { throw TranslationError.missingKey(.deepL) }
            let host = config.apiKey.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
            var body: [String: Any] = ["text": [text], "target_lang": Self.targetCode(target)]
            if let source { body["source_lang"] = Self.sourceCode(source) }
            let data = try await HTTP.postForData(
                "https://\(host)/v2/translate",
                headers: ["Authorization": "DeepL-Auth-Key \(config.apiKey)"], body: body
            )
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let translations = json["translations"] as? [[String: Any]],
                let translated = translations.first?["text"] as? String
            else { throw TranslationError.invalidResponse }
            continuation.yield(translated)
        }
    }

    private static func targetCode(_ language: Language) -> String {
        switch language {
        case .english: "EN-US"
        case .chineseSimplified: "ZH-HANS"
        case .chineseTraditional: "ZH-HANT"
        case .portuguese: "PT-BR"
        default: language.rawValue.uppercased()
        }
    }

    private static func sourceCode(_ language: Language) -> String {
        switch language {
        case .chineseSimplified, .chineseTraditional: "ZH"
        default: language.rawValue.uppercased()
        }
    }
}
