import Foundation
import Testing
@testable import Trot

@MainActor @Suite("Translate controller")
struct ControllerTests {
    @Test func settingsErrorsGetTheSettingsButtonExceptForGoogle() {
        #expect(TranslateController.needsSettings(TranslationError.missingKey(.openAI), for: .openAI))
        #expect(TranslateController.needsSettings(TranslationError.http(401, ""), for: .claude))
        #expect(TranslateController.needsSettings(TranslationError.http(404, ""), for: .openAI))
        #expect(TranslateController.needsSettings(TranslationError.notAStream(Data()), for: .openAI))
        #expect(!TranslateController.needsSettings(TranslationError.http(500, ""), for: .openAI))
        #expect(!TranslateController.needsSettings(URLError(.timedOut), for: .openAI))
        #expect(!TranslateController.needsSettings(TranslationError.http(404, ""), for: .google))
    }

    @Test func longTextIsCutAndShortTextIsNot() {
        let (short, cutShort) = TranslateController.capped("hello")
        #expect(short == "hello" && !cutShort)
        let long = String(repeating: "x", count: TranslateController.maxCharacters + 10)
        let (cut, wasCut) = TranslateController.capped(long)
        #expect(cut.count == TranslateController.maxCharacters && wasCut)
    }

    @Test func theStatusNamesTheCutTheTimeAndTheModel() {
        let status = TranslateController.status(model: nil, elapsed: .milliseconds(1250), cut: false)
        #expect(status == "1.3 s" || status == "1.2 s")
        #expect(TranslateController.status(model: nil, elapsed: .seconds(2), cut: true).hasPrefix("First 20,000 characters · "))
        #expect(TranslateController.status(model: "gpt-4o-mini", elapsed: .seconds(2), cut: false) == "2.0 s · gpt-4o-mini")
    }
}
