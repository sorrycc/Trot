import Testing
@testable import Trot

@Suite("Screenshot text")
struct ScreenOCRTests {
    @Test func latinLinesJoinWithASpace() {
        #expect(ScreenOCR.joinLines(["The quick brown", "fox jumps over", "the lazy dog"]) == "The quick brown fox jumps over the lazy dog")
    }

    @Test func cjkLinesJoinDirectly() {
        #expect(ScreenOCR.joinLines(["敏捷的棕色狐狸", "跳过了懒狗"]) == "敏捷的棕色狐狸跳过了懒狗")
    }

    @Test func aSentenceEndKeepsItsLineBreak() {
        #expect(ScreenOCR.joinLines(["First sentence.", "Second one"]) == "First sentence.\nSecond one")
        #expect(ScreenOCR.joinLines(["第一句。", "第二句"]) == "第一句。\n第二句")
        #expect(ScreenOCR.joinLines(["Title:", "body"]) == "Title:\nbody")
    }

    @Test func blankLinesAreDropped() {
        #expect(ScreenOCR.joinLines(["", "  ", "only"]) == "only")
        #expect(ScreenOCR.joinLines([]) == "")
    }

    @Test func koreanLinesKeepTheirSpaces() {
        #expect(ScreenOCR.joinLines(["안녕하세요", "세계"]) == "안녕하세요 세계")
    }

    @Test func aCJKCharacterOnEitherSideJoinsWithoutASpace() {
        #expect(ScreenOCR.joinLines(["Hello", "世界"]) == "Hello世界")
        #expect(ScreenOCR.joinLines(["世界", "Hello"]) == "世界Hello")
    }
}
