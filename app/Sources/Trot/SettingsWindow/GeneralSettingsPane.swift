import AppKit

/// The two languages, launch at login, and the permissions Trot needs.
final class GeneralSettingsPane: SettingsPane {
    private var firstPopUp: NSPopUpButton?
    private var secondPopUp: NSPopUpButton?
    private let loginSwitch = NSSwitch()
    private var loginRow: SettingsRow?
    private var accessibilityStatus: PermissionStatus?
    private var screenRecordingStatus: PermissionStatus?

    init() { super.init(title: "General") }

    required init?(coder: NSCoder) { fatalError() }

    override func buildGroups() {
        let first = Self.popUp(
            Language.allCases, title: \.displayName, selected: Settings.firstLanguage,
            target: self, action: #selector(firstChanged(_:))
        )
        let second = Self.popUp(
            Language.allCases, title: \.displayName, selected: Settings.secondLanguage,
            target: self, action: #selector(secondChanged(_:))
        )
        firstPopUp = first
        secondPopUp = second
        addGroup(
            [SettingsRow("First language", control: first), SettingsRow("Second language", control: second)],
            footer: Self.note(
                "Text in any other language is translated into the first language. "
                    + "Text already in the first language is translated into the second.")
        )

        loginSwitch.controlSize = .small
        loginSwitch.target = self
        loginSwitch.action = #selector(loginChanged(_:))
        loginSwitch.setAccessibilityLabel("Open Trot at login")
        let login = SettingsRow("Open Trot at login", control: loginSwitch)
        loginRow = login
        addGroup([login])

        let accessibility = PermissionStatus(target: self, action: #selector(openAccessibility(_:)))
        let screenRecording = PermissionStatus(target: self, action: #selector(openScreenRecording(_:)))
        accessibilityStatus = accessibility
        screenRecordingStatus = screenRecording
        addGroup([
            SettingsRow("Accessibility", subtitle: "Reads the selected text in other apps.", control: accessibility),
            SettingsRow("Screen Recording", subtitle: "Reads the text in a screenshot.", control: screenRecording),
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshState(_:)), name: NSApplication.didBecomeActiveNotification, object: nil
        )
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshState(nil)
    }

    @objc private func refreshState(_ notification: Notification?) {
        firstPopUp?.selectItem(at: Language.allCases.firstIndex(of: Settings.firstLanguage) ?? 0)
        secondPopUp?.selectItem(at: Language.allCases.firstIndex(of: Settings.secondLanguage) ?? 0)
        accessibilityStatus?.show(allowed: Accessibility.isTrusted)
        screenRecordingStatus?.show(allowed: ScreenOCR.isAllowed)
        showLoginState()
    }

    /// macOS can hold a login item until the user approves it; the note
    /// says so and where to go.
    private func showLoginState(error: Error? = nil) {
        loginSwitch.state = Settings.launchesAtLogin ? .on : .off
        if let error {
            loginRow?.setNote(error.localizedDescription, style: .warning)
        } else if Settings.loginItemNeedsApproval {
            loginRow?.setNote("Waiting for approval in System Settings › General › Login Items.", style: .warning)
        } else {
            loginRow?.setNote(nil)
        }
        refresh()
    }

    /// Picking the other pop-up's language swaps the two, so the rule
    /// always has somewhere to go.
    @objc private func firstChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let language = Language(rawValue: raw) else { return }
        Settings.setLanguages(first: language, second: Settings.secondLanguage)
        refreshState(nil)
    }

    @objc private func secondChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let language = Language(rawValue: raw) else { return }
        Settings.setLanguages(first: Settings.firstLanguage, second: language)
        refreshState(nil)
    }

    @objc private func loginChanged(_ sender: NSSwitch) {
        do {
            try Settings.setLaunchesAtLogin(sender.state == .on)
            showLoginState()
        } catch {
            showLoginState(error: error)
        }
    }

    @objc private func openAccessibility(_ sender: Any?) {
        Accessibility.prompt()
        Accessibility.openSystemSettings()
    }

    @objc private func openScreenRecording(_ sender: Any?) {
        ScreenOCR.requestAccess()
        ScreenOCR.openSystemSettings()
    }
}
