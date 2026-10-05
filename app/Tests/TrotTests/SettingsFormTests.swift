import AppKit
import Testing
@testable import Trot

@MainActor @Suite("Settings form")
struct SettingsFormTests {
    @Test func hairlinesSeparateOnlyTheRowsThatShow() {
        let rows = (1...3).map { SettingsRow("Row \($0)", control: NSView()) }
        let group = SettingsGroup(rows: rows, footer: nil)
        group.refresh()
        #expect(rows.map(\.showsSeparator) == [false, true, true])
        // The first row gone: the second is the top one now.
        rows[0].isHidden = true
        group.refresh()
        #expect(rows[1].showsSeparator == false && rows[2].showsSeparator)
        #expect(!group.isHidden)
    }

    @Test func aGroupWithNoRowsLeftHidesItsBox() {
        let rows = (1...2).map { SettingsRow("Row \($0)", control: NSView()) }
        let group = SettingsGroup(rows: rows, footer: SettingsPane.note("A note"))
        rows.forEach { $0.isHidden = true }
        group.refresh()
        #expect(group.isHidden)
        rows[1].isHidden = false
        group.refresh()
        #expect(!group.isHidden)
    }

    @Test func aNoteMakesThePaneTaller() {
        final class Pane: SettingsPane {
            let row = SettingsRow("Row", control: NSView())
            override func buildGroups() { addGroup([row]) }
        }
        let pane = Pane(title: "Test")
        pane.loadView()
        let plain = pane.preferredContentSize
        #expect(plain.width == SettingsPane.paneWidth && plain.height > SettingsPane.inset * 2)
        pane.row.setNote("Another app holds this shortcut, so it won't work.", style: .warning)
        pane.refresh()
        #expect(pane.preferredContentSize.height > plain.height)
        pane.row.setNote(nil)
        pane.refresh()
        #expect(pane.preferredContentSize.height == plain.height)
    }

    @Test func controlsSitAtTheRightEdgeWhateverTheTextBesideThem() {
        final class Pane: SettingsPane {
            let short = NSTextField(labelWithString: "On")
            let stacked = NSStackView(views: [NSTextField(labelWithString: "Allowed")])
            override func buildGroups() {
                addGroup([
                    SettingsRow("Row", control: short),
                    SettingsRow("Row", subtitle: "A line of explanation under the title.", control: stacked),
                ])
            }
        }
        let pane = Pane(title: "Test")
        pane.loadView()
        pane.view.frame.size = pane.preferredContentSize
        pane.view.layoutSubtreeIfNeeded()
        // The explanation keeps its whole line.
        func labels(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? labels(in: $0) }
        }
        let subtitle = labels(in: pane.view).first { $0.stringValue.hasPrefix("A line of") }!
        #expect(subtitle.frame.width >= subtitle.intrinsicContentSize.width - 1)
        #expect(subtitle.frame.height < 20)
        let edge = SettingsPane.paneWidth - SettingsPane.inset - SettingsRow.padding
        for control in [pane.short, pane.stacked] as [NSView] {
            // A label's frame reaches a couple of points past its text.
            #expect(abs(control.convert(control.bounds, to: pane.view).maxX - edge) <= 2)
            #expect(!control.hasAmbiguousLayout)
        }
    }
}
