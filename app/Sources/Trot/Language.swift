import Foundation
import NaturalLanguage

/// A language Trot translates from or to.
enum Language: String, CaseIterable, Codable, Sendable {
    case english = "en"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case portuguese = "pt"
    case italian = "it"
    case russian = "ru"
    case arabic = "ar"
    case vietnamese = "vi"
    case thai = "th"

    /// As the menus show it, in the language itself.
    var displayName: String {
        switch self {
        case .english: "English"
        case .chineseSimplified: "简体中文"
        case .chineseTraditional: "繁體中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .french: "Français"
        case .german: "Deutsch"
        case .spanish: "Español"
        case .portuguese: "Português"
        case .italian: "Italiano"
        case .russian: "Русский"
        case .arabic: "العربية"
        case .vietnamese: "Tiếng Việt"
        case .thai: "ไทย"
        }
    }

    /// As prompts name it.
    var englishName: String {
        switch self {
        case .english: "English"
        case .chineseSimplified: "Simplified Chinese"
        case .chineseTraditional: "Traditional Chinese"
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .french: "French"
        case .german: "German"
        case .spanish: "Spanish"
        case .portuguese: "Portuguese"
        case .italian: "Italian"
        case .russian: "Russian"
        case .arabic: "Arabic"
        case .vietnamese: "Vietnamese"
        case .thai: "Thai"
        }
    }

    /// A two or three letter tag for the compact chip in the panel.
    var shortName: String {
        switch self {
        case .english: "EN"
        case .chineseSimplified: "简"
        case .chineseTraditional: "繁"
        case .japanese: "日"
        case .korean: "한"
        default: rawValue.uppercased()
        }
    }

    /// The voice to read the language with.
    var speechLocale: String {
        switch self {
        case .english: "en-US"
        case .chineseSimplified: "zh-CN"
        case .chineseTraditional: "zh-TW"
        case .japanese: "ja-JP"
        case .korean: "ko-KR"
        case .french: "fr-FR"
        case .german: "de-DE"
        case .spanish: "es-ES"
        case .portuguese: "pt-BR"
        case .italian: "it-IT"
        case .russian: "ru-RU"
        case .arabic: "ar-SA"
        case .vietnamese: "vi-VN"
        case .thai: "th-TH"
        }
    }

    var nlLanguage: NLLanguage {
        switch self {
        case .english: .english
        case .chineseSimplified: .simplifiedChinese
        case .chineseTraditional: .traditionalChinese
        case .japanese: .japanese
        case .korean: .korean
        case .french: .french
        case .german: .german
        case .spanish: .spanish
        case .portuguese: .portuguese
        case .italian: .italian
        case .russian: .russian
        case .arabic: .arabic
        case .vietnamese: .vietnamese
        case .thai: .thai
        }
    }

    init?(nlLanguage: NLLanguage) {
        guard let match = Language.allCases.first(where: { $0.nlLanguage == nlLanguage }) else { return nil }
        self = match
    }

    /// Languages whose script no other language here shares, so detection
    /// is never a guess. Cyrillic and Arabic script are not: Ukrainian or
    /// Persian would be called Russian or Arabic.
    var isScriptCertain: Bool {
        switch self {
        case .chineseSimplified, .chineseTraditional, .japanese, .korean, .thai: true
        default: false
        }
    }

    /// Whether the two are the same language apart from script, so Chinese
    /// detected as traditional still counts as the user's Chinese.
    func sameFamily(as other: Language) -> Bool {
        let chinese: Set<Language> = [.chineseSimplified, .chineseTraditional]
        return self == other || (chinese.contains(self) && chinese.contains(other))
    }

    /// How much of a text detection reads.
    static let detectionLimit = 600

    /// The language `text` is written in. Short strings lean on the script
    /// since the recognizer has little to go on. Chinese without a character
    /// that belongs to one script only, such as 你好, is `preferredChinese`.
    static func detect(_ text: String, preferredChinese: Language = .chineseSimplified) -> Language? {
        // The first few hundred characters say what language a text is in;
        // reading a whole article would only make a long selection slower.
        // The prefix comes first, so a long text is never copied whole.
        let trimmed = String(text.prefix(detectionLimit + 64).trimmingCharacters(in: .whitespacesAndNewlines).prefix(detectionLimit))
        guard !trimmed.isEmpty else { return nil }
        if let scripted = detectByScript(trimmed, preferredChinese: preferredChinese) { return scripted }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = Language.allCases.map(\.nlLanguage)
        recognizer.processString(trimmed)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        return Language(nlLanguage: dominant)
    }

    /// Kana means Japanese, Hangul means Korean, and Han without either means
    /// Chinese, which the recognizer gets wrong on short strings.
    private static func detectByScript(_ text: String, preferredChinese: Language) -> Language? {
        var han = 0, kana = 0, hangul = 0, letters = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF: kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF: hangul += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: han += 1
            default: if scalar.properties.isAlphabetic { letters += 1 }
            }
        }
        let cjk = han + kana + hangul
        guard cjk > 0, cjk * 2 >= letters else { return nil }
        if kana > 0 { return .japanese }
        if hangul > 0 { return .korean }
        // The recognizer is sure (1.0) when a character exists in one script
        // only and guesses otherwise; a guess goes to the user's own Chinese.
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese]
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        if hypotheses[.traditionalChinese] ?? 0 >= 0.9 { return .chineseTraditional }
        if hypotheses[.simplifiedChinese] ?? 0 >= 0.9 { return .chineseSimplified }
        return preferredChinese.sameFamily(as: .chineseSimplified) ? preferredChinese : .chineseSimplified
    }
}
