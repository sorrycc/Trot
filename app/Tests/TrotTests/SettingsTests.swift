import Foundation
import Testing
@testable import Trot

@Suite("Two-language rule", .serialized)
struct SettingsTests {
    @Test func pickingTheOtherLanguageSwapsThem() {
        // The first pop-up set to what the second was: the second takes the old first.
        let swapped = Settings.resolved(first: .english, second: .english, before: (.chineseSimplified, .english))
        #expect(swapped == (.english, .chineseSimplified))
        // The second pop-up set to what the first was: the first takes the old second.
        let other = Settings.resolved(first: .chineseSimplified, second: .chineseSimplified, before: (.chineseSimplified, .english))
        #expect(other == (.english, .chineseSimplified))
        // Different languages pass through.
        #expect(Settings.resolved(first: .japanese, second: .english, before: (.chineseSimplified, .english)) == (.japanese, .english))
    }

    @Test func otherLanguagesGoToTheFirstAndTheFirstGoesToTheSecond() {
        let defaults = UserDefaults.standard
        let saved = (defaults.string(forKey: "firstLanguage"), defaults.string(forKey: "secondLanguage"))
        defer {
            defaults.set(saved.0, forKey: "firstLanguage")
            defaults.set(saved.1, forKey: "secondLanguage")
        }
        Settings.firstLanguage = .chineseSimplified
        Settings.secondLanguage = .english
        #expect(Settings.target(for: .english) == .chineseSimplified)
        #expect(Settings.target(for: .japanese) == .chineseSimplified)
        #expect(Settings.target(for: nil) == .chineseSimplified)
        #expect(Settings.target(for: .chineseSimplified) == .english)
        // Traditional Chinese counts as the user's Chinese.
        #expect(Settings.target(for: .chineseTraditional) == .english)
    }
}
