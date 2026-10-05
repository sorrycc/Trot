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
        let actions: [(HotKeyAction, Selector, String)] = [
            (.translateSelection, #selector(AppDelegate.translateSelection(_:)), "character.cursor.ibeam"),
            (.translateInput, #selector(AppDelegate.translateInput(_:)), "keyboard"),
            (.translateScreenshot, #selector(AppDelegate.translateScreenshot(_:)), "text.viewfinder"),
        ]
        for (action, selector, symbol) in actions {
            let menuItem = menu.addItem(withTitle: action.displayName, action: selector, keyEquivalent: "")
            menuItem.target = target
            menuItem.image = Self.symbol(symbol)
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
        serviceItem.image = Self.symbol("globe")
        menu.addItem(.separator())
        let about = menu.addItem(withTitle: "About Trot", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        about.target = target
        about.image = Self.symbol("info.circle")
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        settings.target = target
        settings.image = Self.symbol("gearshape")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Trot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    /// An icon for a menu item, as the system's own menus have them.
    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    @objc private func pickService(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = ServiceKind(rawValue: raw), kind != Settings.service else { return }
        Settings.service = kind
    }
}
