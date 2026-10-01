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

    @Test func thePromptNamesTheLanguages() {
        let prompt = TranslationPrompt.system(from: .english, to: .chineseSimplified)
        #expect(prompt.contains("from English"))
        #expect(prompt.contains("into Simplified Chinese"))
        #expect(!TranslationPrompt.system(from: nil, to: .japanese).contains("from "))
    }

    @Test func errorsReadAsSentences() {
        #expect(TranslationError.missingKey(.deepL).localizedDescription == "DeepL needs an API key.")
        #expect(TranslationError.http(503, "").localizedDescription == "HTTP 503")
        #expect(TranslationError.http(401, "bad key").localizedDescription == "HTTP 401: bad key")
        #expect(TranslationError.notAStream(Data("<html>".utf8)).localizedDescription.contains("base URL"))
        #expect(TranslationError.notAStream(Data(#"{"error":{"message":"Not found"}}"#.utf8)).localizedDescription == "Not found")
    }
}
