import AppKit

/// The menu bar icon and its menu. Shortcuts shown next to the items are the
/// global hotkeys; the items themselves work from the menu.
@MainActor
final class StatusItem: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var target: AppDelegate?

    init(target: AppDelegate) {
        self.target = target
        super.init()
        item.button?.image = Self.icon()
        item.button?.toolTip = "Trot"
        rebuild()
        for name in [Notification.Name.shortcutsDidChange, .serviceDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
            }
        }
    }

    /// The hoof print from the bundle's resources, drawn as a template so
    /// it follows the menu bar's color. A bare binary has no bundle, so it
    /// falls back to a symbol.
    private static func icon() -> NSImage? {
        if let image = NSImage(named: "MenuBarIcon") {
            image.isTemplate = true
            image.accessibilityDescription = "Trot"
            return image
        }
        return NSImage(systemSymbolName: "translate", accessibilityDescription: "Trot")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
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
        // The active service, switchable without opening Settings.
        let services = NSMenu(title: "Service")
        for kind in ServiceKind.allCases {
            let serviceItem = services.addItem(withTitle: kind.displayName, action: #selector(pickService(_:)), keyEquivalent: "")
            serviceItem.target = self
            serviceItem.representedObject = kind.rawValue
            serviceItem.state = kind == Settings.service ? .on : .off
        }
        let serviceItem = menu.addItem(withTitle: "Service: \(Settings.service.shortName)", action: nil, keyEquivalent: "")
        serviceItem.submenu = services
        menu.addItem(.separator())
        let about = menu.addItem(withTitle: "About Trot", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        about.target = target
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        settings.target = target
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Trot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    @objc private func pickService(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = ServiceKind(rawValue: raw), kind != Settings.service else { return }
        Settings.service = kind
    }
}
