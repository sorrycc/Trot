import Foundation
import Testing
@testable import Trot

@Suite("Two-language rule", .serialized)
struct SettingsTests {
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
