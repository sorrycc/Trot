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

    @Test func theStatusNamesTheModelTheTimeAndACut() {
        let status = TranslateController.status(for: .deepL, elapsed: .milliseconds(1250), cut: false)
        #expect(status == "1.3 s" || status == "1.2 s")
        #expect(TranslateController.status(for: .google, elapsed: .seconds(2), cut: true).hasSuffix("characters"))
        #expect(TranslateController.status(for: .openAI, elapsed: .seconds(2), cut: false).hasPrefix(ServiceKind.openAI.activeModel + " · "))
    }
}
