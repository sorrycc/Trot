import AppKit
import Testing
@testable import Trot

@MainActor @Suite("Stream caret")
struct CaretTests {
    private static let font = NSFont.systemFont(ofSize: 15)
    private static let width: CGFloat = 400

    /// A text view as the panel makes its result view, holding `text`.
    private func layout(_ text: String, rightToLeft: Bool = false) -> NSLayoutManager {
        let style = NSMutableParagraphStyle()
        if rightToLeft {
            style.baseWritingDirection = .rightToLeft
            style.alignment = .right
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .paragraphStyle: style]
        let view = PanelTextView.make(width: Self.width, attributes: attributes, nonContiguous: false)
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        return view.layoutManager!
    }

    private func caret(_ text: String, rightToLeft: Bool = false) -> NSRect {
        StreamCaret.frame(afterTextIn: layout(text, rightToLeft: rightToLeft), font: Self.font, rightToLeft: rightToLeft)!
    }

    @Test func itFollowsTheLastCharacter() {
        let text = "Hello world"
        let end = (text as NSString).size(withAttributes: [.font: Self.font]).width
        #expect(abs(caret(text).minX - end) <= 1)
        #expect(caret(text).minY == caret("").minY)
        #expect(caret("").minX == 0)
    }

    @Test func aLineBreakPutsItOnTheNewLine() {
        let one = caret("Hello")
        let two = caret("Hello\n")
        #expect(two.minX == 0)
        #expect(two.minY > one.minY)
    }

    @Test func aWrappedLineKeepsItInsideTheContainer() {
        let long = String(repeating: "word ", count: 60)
        let frame = caret(long)
        #expect(frame.minX >= 0 && frame.maxX <= Self.width)
        #expect(frame.minY > caret("word").minY)
    }

    @Test func arabicEndsOnTheLeft() {
        // Nothing typed yet: the right edge.
        #expect(caret("", rightToLeft: true).maxX == Self.width)
        let arabic = "مرحبا بالعالم"
        let used = (arabic as NSString).size(withAttributes: [.font: Self.font]).width
        let frame = caret(arabic, rightToLeft: true)
        #expect(abs(frame.maxX - (Self.width - used)) <= 2)
        // A name at the end sits right of where the sentence goes on; the
        // caret stays at the left of the whole line.
        let mixed = "مرحبا iPhone"
        let mixedUsed = (mixed as NSString).size(withAttributes: [.font: Self.font]).width
        #expect(abs(caret(mixed, rightToLeft: true).maxX - (Self.width - mixedUsed)) <= 2)
    }
}
