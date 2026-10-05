import AppKit

/// The Settings window (Cmd+,), with General, Services, Shortcuts and About
/// panes. Every change is saved as it is made.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()

    init() {
        tabs.tabStyle = .toolbar
        let panes: [(NSViewController, String)] = [
            (GeneralSettingsPane(), "gearshape"),
            (ServicesSettingsPane(), "globe"),
            (ShortcutsSettingsPane(), "keyboard"),
            (AboutSettingsPane(), "info.circle"),
        ]
        for (pane, symbol) in panes {
            let item = NSTabViewItem(viewController: pane)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        // The toolbar tabs put the pane's name in the title bar from the
        // second pane on; starting with it keeps the title consistent.
        window.title = tabs.tabViewItems.first?.label ?? "Settings"
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showPane(titled title: String) {
        if let index = tabs.tabViewItems.firstIndex(where: { $0.viewController?.title?.caseInsensitiveCompare(title) == .orderedSame }) {
            tabs.selectedTabViewItemIndex = index
        }
    }
}
