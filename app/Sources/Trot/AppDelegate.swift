import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let translator = TranslateController()
    private var statusItem: StatusItem?
    private var settingsController: SettingsWindowController?
    private var lastHotKey: ContinuousClock.Instant?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `-appearance light` or `dark` forces one, for checking both from a script.
        if let name = UserDefaults.standard.string(forKey: "appearance") {
            NSApp.appearance = NSAppearance(named: name == "light" ? .aqua : .darkAqua)
        }
        NSApp.mainMenu = MainMenu.build()
        statusItem = StatusItem(target: self)
        registerHotKeys()
        NotificationCenter.default.addObserver(
            forName: .shortcutsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotKeys() }
        }
        // Reading the selection needs Accessibility. Asking at the first
        // launch means the first hotkey press works; after that the hotkey
        // and Settings ask again.
        if !Accessibility.isTrusted, !UserDefaults.standard.bool(forKey: "accessibilityPrompted") {
            UserDefaults.standard.set(true, forKey: "accessibilityPrompted")
            Accessibility.prompt()
        }
        // `-translate "text"` opens the panel with that text at launch, for
        // trying the panel from a script: open build/Trot.app --args -translate hello
        if let text = UserDefaults.standard.string(forKey: "translate"), !text.isEmpty {
            translator.translate(text, at: NSEvent.mouseLocation)
        }
        // `-input YES` opens the input panel, `-settings <pane>` the Settings window.
        if UserDefaults.standard.bool(forKey: "input") { translator.showInput() }
        if let pane = UserDefaults.standard.string(forKey: "settings") {
            showSettings(nil)
            settingsController?.showPane(titled: pane)
        }
    }

    /// Hotkey ids are the action's position plus one; zero is never used.
    private func registerHotKeys() {
        for (index, action) in HotKeyAction.allCases.enumerated() {
            let id = UInt32(index + 1)
            guard let shortcut = Settings.shortcut(for: action) else {
                HotKeyCenter.shared.unregister(id: id)
                continue
            }
            HotKeyCenter.shared.register(id: id, shortcut: shortcut) { [weak self] in self?.perform(action) }
        }
    }

    /// A held key repeats the hotkey event; one translation per press is enough.
    private func perform(_ action: HotKeyAction) {
        let now = ContinuousClock.now
        if let lastHotKey, lastHotKey.duration(to: now) < .milliseconds(300) { return }
        lastHotKey = now
        switch action {
        case .translateSelection: translator.translateSelection()
        case .translateInput: translator.showInput()
        case .translateScreenshot: translator.translateScreenshot()
        }
    }

    @objc func translateSelection(_ sender: Any?) { translator.translateSelection() }
    @objc func translateInput(_ sender: Any?) { translator.showInput() }
    @objc func translateScreenshot(_ sender: Any?) { translator.translateScreenshot() }

    @objc func showSettings(_ sender: Any?) {
        let controller = settingsController ?? SettingsWindowController()
        settingsController = controller
        NSApp.activate()
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
