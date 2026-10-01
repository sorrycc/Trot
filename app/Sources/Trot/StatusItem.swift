import AppKit

/// The menu bar icon and its menu. Shortcuts shown next to the items are the
/// global hotkeys; the items themselves work from the menu.
@MainActor
final class StatusItem {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var target: AppDelegate?

    init(target: AppDelegate) {
        self.target = target
        let symbol = NSImage(systemSymbolName: "translate", accessibilityDescription: "Trot")
            ?? NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Trot")
        item.button?.image = symbol?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        item.button?.toolTip = "Trot"
        rebuild()
        NotificationCenter.default.addObserver(
            forName: .shortcutsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    private func rebuild() {
        let menu = NSMenu()
        let actions: [(HotKeyAction, Selector)] = [
            (.translateSelection, #selector(AppDelegate.translateSelection(_:))),
            (.translateInput, #selector(AppDelegate.translateInput(_:))),
            (.translateScreenshot, #selector(AppDelegate.translateScreenshot(_:))),
        ]
        for (action, selector) in actions {
            let menuItem = menu.addItem(withTitle: action.displayName, action: selector, keyEquivalent: "")
            menuItem.target = target
            if let shortcut = Settings.shortcut(for: action) {
                menuItem.keyEquivalent = shortcut.key
                menuItem.keyEquivalentModifierMask = shortcut.modifiers
            }
        }
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        settings.target = target
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Trot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }
}
