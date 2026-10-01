import AppKit
import ServiceManagement

/// The Settings window (Cmd+,), with General, Services and Shortcuts panes.
/// Every change is saved as it is made.
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

/// A two-column form: right-aligned labels, controls on the right, and short
/// notes under some controls. Every pane is the same width with the label
/// column at the same place, so switching panes moves nothing sideways.
@MainActor
class SettingsPane: NSViewController {
    let grid = NSGridView()
    static let controlWidth: CGFloat = 340
    static let popUpWidth: CGFloat = 200
    static let paneWidth: CGFloat = 540
    static let labelWidth: CGFloat = 140
    private var lastRow: NSGridRow?

    init(title: String) {
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = NSView()
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.paneWidth),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
        ])
        self.view = view
        buildRows()
        if grid.numberOfColumns > 0 {
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 0).width = Self.labelWidth
        }
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.paneWidth, height: view.fittingSize.height)
    }

    /// Subclasses add their rows here.
    func buildRows() {}

    /// A labelled row. Rows are spaced the same whether or not a note
    /// follows: the gap goes under the note when there is one.
    @discardableResult
    func addRow(_ label: String, _ control: NSView) -> NSGridRow {
        let row = grid.addRow(with: [NSTextField(labelWithString: label), control])
        row.bottomPadding = 6
        lastRow = row
        return row
    }

    /// A note under the control in the row above.
    @discardableResult
    func addNote(_ note: NSView) -> NSGridRow {
        lastRow?.bottomPadding = 0
        let row = grid.addRow(with: [NSGridCell.emptyContentView, note])
        row.topPadding = -4
        row.bottomPadding = 6
        return row
    }

    static func note(_ text: String = "", lines: Int = 2) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = lines
        label.preferredMaxLayoutWidth = controlWidth
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func show(_ text: String, in note: NSTextField, warning: Bool = false) {
        note.stringValue = text
        note.textColor = warning ? .systemRed : .secondaryLabelColor
    }

    /// A small text link that opens `url`.
    static func link(_ title: String, to url: String) -> LinkButton {
        LinkButton(title: title, url: url)
    }

    static func fixWidth(_ view: NSView, _ width: CGFloat = controlWidth) -> NSView {
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }

    /// Pop-ups share one width, so the right edge of the form stays straight.
    static func popUp<T: RawRepresentable<String> & Equatable>(
        _ cases: [T], title: (T) -> String, selected: T, target: AnyObject, action: Selector
    ) -> NSPopUpButton {
        let button = NSPopUpButton()
        for value in cases {
            button.addItem(withTitle: title(value))
            button.lastItem?.representedObject = value.rawValue
        }
        button.selectItem(at: cases.firstIndex(of: selected) ?? 0)
        button.target = target
        button.action = action
        _ = fixWidth(button, popUpWidth)
        return button
    }
}

/// A coloured dot and a word, for the state of a permission.
@MainActor
final class StatusLine: NSStackView {
    private let dot = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .regular))
        spacing = 5
        alignment = .firstBaseline
        addArrangedSubview(dot)
        addArrangedSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, ok: Bool) {
        label.stringValue = text
        dot.contentTintColor = ok ? .systemGreen : .systemOrange
        setAccessibilityLabel(text)
    }
}

// MARK: General

final class GeneralSettingsPane: SettingsPane {
    private var firstPopUp: NSPopUpButton?
    private var secondPopUp: NSPopUpButton?
    private let loginCheckbox = NSButton(checkboxWithTitle: "Open Trot at login", target: nil, action: nil)
    private let loginNote = SettingsPane.note()
    private var loginRow: NSGridRow?
    private var loginNoteRow: NSGridRow?
    private let accessibilityStatus = StatusLine()
    private let accessibilityButton = NSButton(title: "Open System Settings…", target: nil, action: nil)

    init() { super.init(title: "General") }

    required init?(coder: NSCoder) { fatalError() }

    override func buildRows() {
        let first = Self.popUp(
            Language.allCases, title: \.displayName, selected: Settings.firstLanguage,
            target: self, action: #selector(firstChanged(_:))
        )
        firstPopUp = first
        addRow("First language:", first)
        addNote(Self.note("Text in any other language is translated into this one."))

        let second = Self.popUp(
            Language.allCases, title: \.displayName, selected: Settings.secondLanguage,
            target: self, action: #selector(secondChanged(_:))
        )
        secondPopUp = second
        addRow("Second language:", second)
        addNote(Self.note("Text already in the first language is translated into this one."))

        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginChanged(_:))
        loginRow = addRow("Launch:", loginCheckbox)
        loginNoteRow = addNote(loginNote)

        accessibilityButton.target = self
        accessibilityButton.action = #selector(openAccessibility(_:))
        accessibilityButton.controlSize = .small
        let row = NSStackView(views: [accessibilityStatus, accessibilityButton])
        row.spacing = 10
        row.alignment = .firstBaseline
        addRow("Accessibility:", row)
        addNote(Self.note("Needed to read the selected text in other apps."))
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh(_:)), name: NSApplication.didBecomeActiveNotification, object: nil
        )
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh(nil)
    }

    @objc private func refresh(_ notification: Notification?) {
        firstPopUp?.selectItem(at: Language.allCases.firstIndex(of: Settings.firstLanguage) ?? 0)
        secondPopUp?.selectItem(at: Language.allCases.firstIndex(of: Settings.secondLanguage) ?? 0)
        loginCheckbox.state = Settings.launchesAtLogin ? .on : .off
        showLoginState()
        let trusted = Accessibility.isTrusted
        accessibilityStatus.show(trusted ? "Allowed" : "Not allowed", ok: trusted)
        accessibilityButton.isHidden = trusted
    }

    /// macOS can hold a login item until the user approves it; the note
    /// says so and where to go.
    private func showLoginState(error: Error? = nil) {
        if let error {
            Self.show(error.localizedDescription, in: loginNote, warning: true)
        } else if Settings.loginItemNeedsApproval {
            Self.show("Waiting for approval in System Settings › General › Login Items.", in: loginNote, warning: true)
        }
        let hidden = error == nil && !Settings.loginItemNeedsApproval
        loginNoteRow?.isHidden = hidden
        // Without its note the row keeps the gap the note would have left.
        loginRow?.bottomPadding = hidden ? 6 : 0
    }

    /// Picking the other pop-up's language swaps the two, so the rule
    /// always has somewhere to go.
    @objc private func firstChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let language = Language(rawValue: raw) else { return }
        Settings.setLanguages(first: language, second: Settings.secondLanguage)
        refresh(nil)
    }

    @objc private func secondChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let language = Language(rawValue: raw) else { return }
        Settings.setLanguages(first: Settings.firstLanguage, second: language)
        refresh(nil)
    }

    @objc private func loginChanged(_ sender: NSButton) {
        do {
            try Settings.setLaunchesAtLogin(sender.state == .on)
            showLoginState()
        } catch {
            showLoginState(error: error)
        }
        sender.state = Settings.launchesAtLogin ? .on : .off
    }

    @objc private func openAccessibility(_ sender: Any?) {
        Accessibility.prompt()
        Accessibility.openSystemSettings()
    }
}

// MARK: Services

final class ServicesSettingsPane: SettingsPane, NSTextFieldDelegate {
    private var servicePopUp: NSPopUpButton?
    private let baseURLField = NSTextField()
    private let baseURLNote = SettingsPane.note()
    private var baseURLNoteRow: NSGridRow?
    private let keyField = NSSecureTextField()
    private let modelField = NSTextField()
    private let serviceNote = SettingsPane.note()
    private let keyLink = SettingsPane.link("", to: "")
    private var keyLinkRow: NSGridRow?
    private let testButton = NSButton(title: "Test", target: nil, action: nil)
    private let testSpinner = NSProgressIndicator()
    private let testIcon = NSImageView()
    private let testNote = SettingsPane.note(lines: 3)
    private var testRow: NSGridRow?
    private var baseURLRow: NSGridRow?
    private var keyRow: NSGridRow?
    private var modelRow: NSGridRow?
    private var testTask: Task<Void, Never>?

    private var kind: ServiceKind { Settings.service }

    init() { super.init(title: "Services") }

    required init?(coder: NSCoder) { fatalError() }

    override func buildRows() {
        let popUp = Self.popUp(
            ServiceKind.allCases, title: \.displayName, selected: Settings.service,
            target: self, action: #selector(serviceChanged(_:))
        )
        servicePopUp = popUp
        addRow("Service:", popUp)
        addNote(serviceNote)

        for field in [baseURLField, keyField, modelField] {
            field.delegate = self
            field.usesSingleLineMode = true
        }
        baseURLRow = addRow("Base URL:", Self.fixWidth(baseURLField))
        baseURLNoteRow = addNote(baseURLNote)
        keyRow = addRow("API key:", Self.fixWidth(keyField))
        keyLinkRow = addNote(keyLink)
        modelRow = addRow("Model:", Self.fixWidth(modelField))

        testButton.target = self
        testButton.action = #selector(test(_:))
        testSpinner.style = .spinning
        testSpinner.controlSize = .small
        testSpinner.isDisplayedWhenStopped = false
        let row = NSStackView(views: [testButton, testSpinner])
        row.spacing = 8
        addRow("", row)
        testIcon.setContentHuggingPriority(.required, for: .horizontal)
        let result = NSStackView(views: [testIcon, testNote])
        result.spacing = 5
        result.alignment = .firstBaseline
        testRow = addNote(result)
        NotificationCenter.default.addObserver(
            self, selector: #selector(serviceDidChange(_:)), name: .serviceDidChange, object: nil
        )
        showService()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        showService()
    }

    @objc private func serviceDidChange(_ notification: Notification) {
        showService()
    }

    /// Fills the fields for the active service and hides the ones it has no use for.
    private func showService() {
        let kind = kind
        // A test still running belongs to the service before this one.
        testTask?.cancel()
        testTask = nil
        servicePopUp?.selectItem(at: ServiceKind.allCases.firstIndex(of: kind) ?? 0)
        baseURLRow?.isHidden = !kind.hasBaseURL
        keyRow?.isHidden = !kind.needsKey
        if let page = kind.keyPage {
            keyLink.set(title: "Get an API key from \(kind.shortName)…", url: page)
        }
        keyLinkRow?.isHidden = kind.keyPage == nil
        modelRow?.isHidden = !kind.hasModel
        baseURLField.stringValue = Settings.baseURL(for: kind)
        baseURLField.placeholderString = kind.defaultBaseURL
        keyField.stringValue = Settings.apiKey(for: kind)
        modelField.stringValue = Settings.model(for: kind)
        modelField.placeholderString = kind.defaultModel
        showBaseURLState()
        showTest(nil, symbol: nil)
        let note: String =
            switch kind {
            case .openAI: "Any chat completions API: OpenAI, DeepSeek, Qwen, Ollama. Streams the translation. Keys are stored on this Mac only."
            case .claude: "Anthropic's Messages API, streamed. The base URL can point at a proxy."
            case .deepL: "A key ending in :fx uses the free API, any other the Pro API."
            case .google: "Uses the endpoint Google's web client uses. No key, but unofficial, so it may stop working."
            }
        Self.show(note, in: serviceNote)
    }

    /// Says what the typed base URL amounts to when that isn't obvious: a
    /// scheme added, an endpoint path dropped, or nothing usable at all.
    private func showBaseURLState() {
        let typed = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = ServiceKind.normalizedBaseURL(typed, for: kind)
        if typed.isEmpty {
            baseURLNoteRow?.isHidden = true
        } else if URL(string: normalized)?.host() == nil {
            Self.show("Enter a URL such as \(kind.defaultBaseURL).", in: baseURLNote, warning: true)
            baseURLNoteRow?.isHidden = false
        } else if normalized != typed {
            Self.show("Requests go to \(normalized).", in: baseURLNote)
            baseURLNoteRow?.isHidden = false
        } else {
            baseURLNoteRow?.isHidden = true
        }
    }

    @objc private func serviceChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let kind = ServiceKind(rawValue: raw) else { return }
        Settings.service = kind
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === baseURLField {
            Settings.setBaseURL(field.stringValue, for: kind)
            showBaseURLState()
        } else if field === keyField {
            Settings.setAPIKey(field.stringValue, for: kind)
        } else if field === modelField {
            Settings.setModel(field.stringValue, for: kind)
        }
    }

    /// Translates a short sentence with the current settings and shows the result.
    @objc private func test(_ sender: Any?) {
        testTask?.cancel()
        let kind = kind
        let service = kind.makeService()
        showTest("Translating a sentence…", symbol: nil)
        testButton.isEnabled = false
        testSpinner.startAnimation(nil)
        testTask = Task { [weak self] in
            defer {
                self?.testButton.isEnabled = true
                self?.testSpinner.stopAnimation(nil)
            }
            do {
                var result = ""
                // Into whatever English goes to, so the result always differs.
                for try await chunk in service.translate("The quick brown fox jumps over the lazy dog.", from: .english, to: Settings.target(for: .english)) {
                    result += chunk
                }
                guard !Task.isCancelled, let self else { return }
                let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    showTest("\(kind.displayName) sent back an empty translation.", symbol: "xmark.octagon.fill", tint: .systemRed)
                } else {
                    showTest(text, symbol: "checkmark.circle.fill", tint: .systemGreen)
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                showTest(error.localizedDescription, symbol: "xmark.octagon.fill", tint: .systemRed)
            }
        }
    }

    private func showTest(_ text: String?, symbol: String?, tint: NSColor = .secondaryLabelColor) {
        testNote.stringValue = text ?? ""
        testNote.toolTip = text
        testNote.textColor = symbol == nil ? .secondaryLabelColor : .labelColor
        testIcon.isHidden = symbol == nil
        if let symbol {
            testIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            testIcon.contentTintColor = tint
        }
        testRow?.isHidden = text == nil
    }
}

// MARK: Shortcuts

final class ShortcutsSettingsPane: SettingsPane {
    private var recorders: [HotKeyAction: ShortcutRecorder] = [:]
    private var resets: [HotKeyAction: NSButton] = [:]
    private var notes: [HotKeyAction: NSTextField] = [:]
    private var noteRows: [HotKeyAction: NSGridRow] = [:]

    init() { super.init(title: "Shortcuts") }

    required init?(coder: NSCoder) { fatalError() }

    override func buildRows() {
        for action in HotKeyAction.allCases {
            let recorder = ShortcutRecorder()
            recorder.shortcut = Settings.shortcut(for: action)
            recorder.onRecord = { [weak self] shortcut in self?.record(shortcut, for: action) }
            let reset = NSButton(title: "Reset", target: self, action: #selector(reset(_:)))
            reset.bezelStyle = .accessoryBarAction
            reset.controlSize = .small
            reset.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            reset.toolTip = "Back to \(action.defaultShortcut.displayString)"
            let row = NSStackView(views: [recorder, reset])
            row.spacing = 8
            addRow(action.displayName.replacingOccurrences(of: "…", with: "") + ":", row)
            let note = Self.note()
            notes[action] = note
            noteRows[action] = addNote(note)
            recorders[action] = recorder
            resets[action] = reset
            showState(for: action)
        }
        addNote(Self.note("Click a shortcut, then press the keys. Delete clears it."))
    }

    private func record(_ shortcut: Shortcut?, for action: HotKeyAction) {
        if let shortcut, let taken = HotKeyAction.allCases.first(where: { $0 != action && Settings.shortcut(for: $0) == shortcut }) {
            Self.show("Already used by \(taken.displayName).", in: notes[action]!, warning: true)
            noteRows[action]?.isHidden = false
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
            Self.show("\(standard.displayString) is used by \(taken.displayName).", in: notes[action]!, warning: true)
            noteRows[action]?.isHidden = false
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
        guard let note = notes[action] else { return }
        let id = UInt32((HotKeyAction.allCases.firstIndex(of: action) ?? 0) + 1)
        let taken = Settings.shortcut(for: action) != nil && !HotKeyCenter.shared.isRegistered(id: id)
        Self.show(taken ? "Another app holds this shortcut, so it won't work." : "", in: note, warning: true)
        noteRows[action]?.isHidden = !taken
        resets[action]?.isEnabled = Settings.shortcutIsCustom(for: action)
    }
}

// MARK: About

/// The app icon, the version and where the project lives.
final class AboutSettingsPane: SettingsPane {
    init() { super.init(title: "About") }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = NSView()
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setContentHuggingPriority(.required, for: .vertical)

        let name = NSTextField(labelWithString: "Trot")
        name.font = .systemFont(ofSize: 22, weight: .bold)
        let version = NSTextField(labelWithString: "Version \(Self.version)")
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor
        // Copyable, for bug reports.
        version.isSelectable = true

        let blurb = NSTextField(wrappingLabelWithString:
            "A translation panel for the menu bar: three hotkeys, one floating card, native AppKit. "
            + "Trot keeps no history and sends text only to the service you chose.")
        blurb.font = .systemFont(ofSize: 12)
        blurb.textColor = .secondaryLabelColor
        blurb.alignment = .center
        blurb.preferredMaxLayoutWidth = 360

        let links = NSStackView(views: [
            Self.link("Website", to: AppInfo.homepage),
            Self.link("Report a Problem", to: AppInfo.issues),
            Self.link("MIT License", to: AppInfo.license),
        ])
        links.spacing = 18

        let copyright = NSTextField(labelWithString: AppInfo.copyright)
        copyright.font = .systemFont(ofSize: 11)
        copyright.textColor = .tertiaryLabelColor

        let column = NSStackView(views: [icon, name, version, blurb, links, copyright])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 6
        column.setCustomSpacing(10, after: icon)
        column.setCustomSpacing(14, after: version)
        column.setCustomSpacing(16, after: blurb)
        column.setCustomSpacing(16, after: links)
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.paneWidth),
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            column.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            column.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            column.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
        ])
        self.view = view
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.paneWidth, height: view.fittingSize.height)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String
        return build == nil || build == short ? short : "\(short) (\(build!))"
    }
}

/// A borderless button drawn as a link, opening a URL.
@MainActor
final class LinkButton: NSButton {
    private var url: String

    init(title: String, url: String) {
        self.url = url
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(open(_:))
        set(title: title, url: url)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(title: String, url: String) {
        self.url = url
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.linkColor,
        ])
        toolTip = url
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func open(_ sender: Any?) {
        guard let target = URL(string: url) else { return }
        NSWorkspace.shared.open(target)
    }
}
