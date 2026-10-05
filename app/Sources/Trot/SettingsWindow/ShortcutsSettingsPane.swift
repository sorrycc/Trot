import AppKit

/// The three global hotkeys, each with a recorder and a way back to its default.
final class ShortcutsSettingsPane: SettingsPane {
    private var recorders: [HotKeyAction: ShortcutRecorder] = [:]
    private var resets: [HotKeyAction: NSButton] = [:]
    private var rows: [HotKeyAction: SettingsRow] = [:]

    init() { super.init(title: "Shortcuts") }

    required init?(coder: NSCoder) { fatalError() }

    override func buildGroups() {
        for action in HotKeyAction.allCases {
            let recorder = ShortcutRecorder()
            recorder.shortcut = Settings.shortcut(for: action)
            recorder.onRecord = { [weak self] shortcut in self?.record(shortcut, for: action) }
            let tip = "Back to \(action.defaultShortcut.displayString)"
            let reset = NSButton(
                image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: tip)!,
                target: self, action: #selector(reset(_:))
            )
            reset.bezelStyle = .accessoryBarAction
            reset.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            reset.toolTip = tip
            reset.setAccessibilityLabel(tip)
            let control = NSStackView(views: [recorder, reset])
            control.spacing = 6
            rows[action] = SettingsRow(action.displayName.replacingOccurrences(of: "…", with: ""), control: control)
            recorders[action] = recorder
            resets[action] = reset
        }
        addGroup(
            HotKeyAction.allCases.compactMap { rows[$0] },
            footer: Self.note("Click a shortcut, then press the keys. Delete clears it.")
        )
        HotKeyAction.allCases.forEach(showState)
    }

    private func record(_ shortcut: Shortcut?, for action: HotKeyAction) {
        if let shortcut, let taken = HotKeyAction.allCases.first(where: { $0 != action && Settings.shortcut(for: $0) == shortcut }) {
            rows[action]?.setNote("Already used by \(taken.displayName).", style: .warning)
            refresh()
            return
        }
        Settings.setShortcut(shortcut, for: action)
        recorders[action]?.shortcut = shortcut
        showState(for: action)
    }

    @objc private func reset(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let action = HotKeyAction(rawValue: raw) else { return }
        let standard = action.defaultShortcut
        if let taken = HotKeyAction.allCases.first(where: { $0 != action && Settings.shortcut(for: $0) == standard }) {
            rows[action]?.setNote("\(standard.displayString) is used by \(taken.displayName).", style: .warning)
            refresh()
            return
        }
        Settings.resetShortcut(for: action)
        recorders[action]?.shortcut = Settings.shortcut(for: action)
        showState(for: action)
    }

    /// Registration happens when the setting changes, so by now it's known
    /// whether another app holds the combination. Reset only has work to
    /// do when the shortcut differs from the default.
    private func showState(for action: HotKeyAction) {
        let taken = Settings.shortcut(for: action) != nil && !HotKeyCenter.shared.isRegistered(id: action.hotKeyID)
        rows[action]?.setNote(taken ? "Another app holds this shortcut, so it won't work." : nil, style: .warning)
        resets[action]?.isEnabled = Settings.shortcutIsCustom(for: action)
        refresh()
    }
}
