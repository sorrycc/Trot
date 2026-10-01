import Testing
@testable import Trot

@Suite("Language detection")
struct LanguageTests {
    @Test func englishSentence() {
        #expect(Language.detect("The quick brown fox jumps over the lazy dog.") == .english)
    }

    @Test func shortChineseIsNotMistakenForJapanese() {
        #expect(Language.detect("你好") == .chineseSimplified)
        #expect(Language.detect("翻译") == .chineseSimplified)
    }

    @Test func ambiguousChineseGoesToTheUsersScript() {
        // 你好 is written the same in both scripts.
        #expect(Language.detect("你好", preferredChinese: .chineseTraditional) == .chineseTraditional)
        #expect(Language.detect("你好", preferredChinese: .chineseSimplified) == .chineseSimplified)
        #expect(Language.detect("你好", preferredChinese: .english) == .chineseSimplified)
        // Script evidence wins over the preference.
        #expect(Language.detect("我们", preferredChinese: .chineseTraditional) == .chineseSimplified)
        #expect(Language.detect("我們", preferredChinese: .chineseSimplified) == .chineseTraditional)
    }

    @Test func traditionalChinese() {
        #expect(Language.detect("這是一段繁體中文的測試文字，用來檢查語言辨識是否正確。") == .chineseTraditional)
    }

    @Test func kanaMeansJapanese() {
        #expect(Language.detect("こんにちは、世界") == .japanese)
    }

    @Test func hangulMeansKorean() {
        #expect(Language.detect("안녕하세요") == .korean)
    }

    @Test func mixedTextLeansOnTheScriptOnlyWhenItDominates() {
        // Two CJK characters inside an English sentence: the sentence wins.
        #expect(Language.detect("The word 你好 means hello in Chinese, as everyone learns first.") == .english)
    }

    @Test func emptyAndBlankTextHaveNoLanguage() {
        #expect(Language.detect("") == nil)
        #expect(Language.detect("   \n\t") == nil)
    }

    @Test func detectionReadsOnlyAPrefix() {
        // A Chinese prefix followed by a long English tail: the prefix decides.
        let text = String(repeating: "这是一个测试。", count: 200) + String(repeating: "English text. ", count: 500)
        #expect(Language.detect(text) == .chineseSimplified)
    }

    @Test func chineseScriptsAreOneFamily() {
        #expect(Language.chineseSimplified.sameFamily(as: .chineseTraditional))
        #expect(Language.chineseTraditional.sameFamily(as: .chineseSimplified))
        #expect(Language.english.sameFamily(as: .english))
        #expect(!Language.english.sameFamily(as: .french))
    }

    @Test func everyLanguageRoundTripsThroughItsRawValue() {
        for language in Language.allCases {
            #expect(Language(rawValue: language.rawValue) == language)
            #expect(Language(nlLanguage: language.nlLanguage) == language)
            #expect(!language.displayName.isEmpty)
            #expect(!language.englishName.isEmpty)
        }
    }
}
