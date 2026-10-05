import Foundation

/// Google Translate through the endpoint its web client uses. No key, but
/// unofficial, so it can stop working without notice.
struct GoogleService: TranslationService {
    let kind = ServiceKind.google

    static let host = "https://translate.googleapis.com"

    func translate(_ text: String, from source: Language?, to target: Language) -> AsyncThrowingStream<String, Error> {
        HTTP.stream { continuation in
            // The text goes in a form body, where "+" and "&" are escaped and
            // long selections don't run into URL length limits.
            let url = Self.host + "/translate_a/single?client=gtx&dt=t"
                + "&sl=\(source.flatMap { $0.isScriptCertain ? Self.code($0) : nil } ?? "auto")&tl=\(Self.code(target))"
            let data = try await HTTP.postForData(
                url, headers: ["User-Agent": "Mozilla/5.0"], body: HTTP.formBody([("q", text)]),
                contentType: "application/x-www-form-urlencoded; charset=utf-8"
            )
            // [[["translated", "source", null, null, 10], ...], null, "en", ...]
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                let sentences = json.first as? [[Any]]
            else { throw TranslationError.invalidResponse }
            let translated = sentences.compactMap { $0.first as? String }.joined()
            continuation.yield(translated)
        }
    }

    static func code(_ language: Language) -> String {
        switch language {
        case .chineseSimplified: "zh-CN"
        case .chineseTraditional: "zh-TW"
        default: language.rawValue
        }
    }
}
