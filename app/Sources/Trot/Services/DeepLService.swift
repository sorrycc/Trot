import Foundation

/// DeepL's REST API. Free keys end in `:fx` and go to the free host.
struct DeepLService: TranslationService {
    let kind = ServiceKind.deepL
    let config: ServiceConfig

    func translate(_ text: String, from source: Language?, to target: Language) -> AsyncThrowingStream<String, Error> {
        let config = config
        return HTTP.stream { continuation in
            guard !config.apiKey.isEmpty else { throw TranslationError.missingKey(.deepL) }
            var body: [String: Any] = ["text": [text], "target_lang": Self.targetCode(target)]
            // The service detects Latin-script languages better than a local
            // guess on a short string; a CJK script is certain either way.
            if let source, source.isScriptCertain { body["source_lang"] = Self.sourceCode(source) }
            let data = try await HTTP.postForData(
                Self.host(forKey: config.apiKey) + "/v2/translate",
                headers: ["Authorization": "DeepL-Auth-Key \(config.apiKey)"], body: body
            )
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let translations = json["translations"] as? [[String: Any]],
                let translated = translations.first?["text"] as? String
            else { throw TranslationError.invalidResponse }
            continuation.yield(translated)
        }
    }

    /// Free keys end in `:fx` and have a host of their own.
    static func host(forKey key: String) -> String {
        key.hasSuffix(":fx") ? "https://api-free.deepl.com" : "https://api.deepl.com"
    }

    static func targetCode(_ language: Language) -> String {
        switch language {
        case .english: "EN-US"
        case .chineseSimplified: "ZH-HANS"
        case .chineseTraditional: "ZH-HANT"
        case .portuguese: "PT-BR"
        default: language.rawValue.uppercased()
        }
    }

    static func sourceCode(_ language: Language) -> String {
        switch language {
        case .chineseSimplified, .chineseTraditional: "ZH"
        default: language.rawValue.uppercased()
        }
    }
}
