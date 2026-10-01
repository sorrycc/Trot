import Foundation
import Testing
@testable import Trot

@Suite("HTTP helpers")
struct HTTPTests {
    @Test func formBodyEscapesReservedCharacters() {
        let body = String(decoding: HTTP.formBody([("q", "a+b&c=d e/ü"), ("tl", "zh-CN")]), as: UTF8.self)
        #expect(body == "q=a%2Bb%26c%3Dd%20e%2F%C3%BC&tl=zh-CN")
    }

    @Test func errorMessageReadsTheCommonShapes() {
        #expect(HTTP.errorMessage(in: Data(#"{"error":{"message":"Invalid API key","type":"auth"}}"#.utf8)) == "Invalid API key")
        #expect(HTTP.errorMessage(in: Data(#"{"message":"Wrong endpoint"}"#.utf8)) == "Wrong endpoint")
        #expect(HTTP.errorMessage(in: Data(#"{"error":"quota exceeded"}"#.utf8)) == "quota exceeded")
    }

    @Test func aShortPlainBodyIsTheMessageMarkupIsNot() {
        #expect(HTTP.errorMessage(in: Data("  Service Unavailable \n".utf8)) == "Service Unavailable")
        #expect(HTTP.errorMessage(in: Data("<html><body>404</body></html>".utf8)) == "")
        #expect(HTTP.errorMessage(in: Data(#"{"detail":"something"}"#.utf8)) == "")
        let page = String(repeating: "x", count: 500)
        #expect(HTTP.errorMessage(in: Data(page.utf8)) == "")
    }

    @Test func baseURLsAreTidied() {
        #expect(ServiceKind.normalizedBaseURL("api.openai.com/v1", for: .openAI) == "https://api.openai.com/v1")
        #expect(ServiceKind.normalizedBaseURL("https://api.openai.com/v1/chat/completions", for: .openAI) == "https://api.openai.com/v1")
        #expect(ServiceKind.normalizedBaseURL("https://api.openai.com/v1//", for: .openAI) == "https://api.openai.com/v1")
        #expect(ServiceKind.normalizedBaseURL("https://api.anthropic.com/v1", for: .claude) == "https://api.anthropic.com")
        #expect(ServiceKind.normalizedBaseURL("https://api.anthropic.com/v1/messages", for: .claude) == "https://api.anthropic.com")
        #expect(ServiceKind.normalizedBaseURL("http://localhost:11434/v1", for: .openAI) == "http://localhost:11434/v1")
        // A machine on the desk rarely speaks TLS.
        #expect(ServiceKind.normalizedBaseURL("localhost:11434/v1", for: .openAI) == "http://localhost:11434/v1")
        #expect(ServiceKind.normalizedBaseURL("127.0.0.1:8080/v1/", for: .openAI) == "http://127.0.0.1:8080/v1")
        #expect(ServiceKind.normalizedBaseURL("mini.local:1234/v1", for: .openAI) == "http://mini.local:1234/v1")
        #expect(ServiceKind.normalizedBaseURL("api.deepseek.com", for: .openAI) == "https://api.deepseek.com")
        #expect(ServiceKind.normalizedBaseURL("  ", for: .openAI) == "")
    }

    @Test func baseURLLosesItsTrailingSlash() {
        #expect(ServiceConfig(baseURL: "https://api.openai.com/v1/", apiKey: "", model: "").trimmedBaseURL == "https://api.openai.com/v1")
        #expect(ServiceConfig(baseURL: "https://api.openai.com/v1", apiKey: "", model: "").trimmedBaseURL == "https://api.openai.com/v1")
    }

    @Test func aBadURLFailsBeforeAnyRequest() async {
        await #expect(throws: TranslationError.self) {
            _ = try await HTTP.postForData("not a url", headers: [:], body: [:])
        }
        await #expect(throws: TranslationError.self) {
            _ = try await HTTP.postForData("/chat/completions", headers: [:], body: [:])
        }
    }

    @Test func sseEventParsesJSONAndToleratesGarbage() {
        #expect(SSEEvent(data: Data(#"{"a":1}"#.utf8)).json["a"] as? Int == 1)
        #expect(SSEEvent(data: Data("nope".utf8)).json.isEmpty)
    }
}

@Suite("Services")
struct ServiceTests {
    @Test func everyServiceKnowsWhatItNeeds() {
        #expect(ServiceKind.google.needsKey == false)
        #expect(ServiceKind.google.keyPage == nil)
        for kind in ServiceKind.allCases where kind != .google {
            #expect(kind.needsKey)
            #expect(kind.keyPage?.hasPrefix("https://") == true)
        }
        for kind in ServiceKind.allCases where kind.hasBaseURL {
            #expect(kind.defaultBaseURL.hasPrefix("https://"))
            #expect(!kind.defaultModel.isEmpty)
        }
    }

    @Test func serviceLanguageCodesMatchTheirAPIs() {
        #expect(DeepLService.targetCode(.english) == "EN-US")
        #expect(DeepLService.targetCode(.chineseSimplified) == "ZH-HANS")
        #expect(DeepLService.targetCode(.german) == "DE")
        #expect(DeepLService.sourceCode(.chineseTraditional) == "ZH")
        #expect(GoogleService.code(.chineseTraditional) == "zh-TW")
        #expect(GoogleService.code(.japanese) == "ja")
    }

    @Test func claude5ModelsAreToldApart() {
        #expect(ClaudeService.isClaude5("claude-opus-5-5"))
        #expect(ClaudeService.isClaude5("claude-sonnet-5-5"))
        #expect(!ClaudeService.isClaude5("claude-3-5-sonnet-latest"))
    }

    @Test func thePromptNamesTheLanguages() {
        let prompt = TranslationPrompt.system(from: .english, to: .chineseSimplified)
        #expect(prompt.contains("from English"))
        #expect(prompt.contains("into Simplified Chinese"))
        #expect(!TranslationPrompt.system(from: nil, to: .japanese).contains("from "))
    }

    @Test func errorsReadAsSentences() {
        #expect(TranslationError.missingKey(.deepL).localizedDescription == "DeepL needs an API key.")
        #expect(TranslationError.http(401, "bad key").localizedDescription == "HTTP 401: bad key")
        // A status without a message gets a sentence of its own.
        #expect(TranslationError.http(503, "").localizedDescription.contains("(HTTP 503)"))
        #expect(TranslationError.http(401, "").localizedDescription.contains("API key"))
        #expect(TranslationError.http(404, "").localizedDescription.contains("base URL"))
        #expect(TranslationError.http(413, "").localizedDescription.contains("too long"))
        #expect(TranslationError.http(418, "").localizedDescription == "HTTP 418")
        #expect(TranslationError.notAStream(Data("<html>".utf8)).localizedDescription.contains("base URL"))
        #expect(TranslationError.notAStream(Data(#"{"error":{"message":"Not found"}}"#.utf8)).localizedDescription == "Not found")
    }
}
