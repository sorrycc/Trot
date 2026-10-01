import AppKit

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
        ]
        for (pane, symbol) in panes {
            let item = NSTabViewItem(viewController: pane)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.title = "Trot Settings"
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
/// notes under some controls.
@MainActor
class SettingsPane: NSViewController {
    let grid = NSGridView()
    static let controlWidth: CGFloat = 340

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
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        self.view = view
        buildRows()
        grid.column(at: 0).xPlacement = .trailing
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    /// Subclasses add their rows here.
    func buildRows() {}

    @discardableResult
    func addRow(_ label: String, _ control: NSView) -> NSGridRow {
        grid.addRow(with: [NSTextField(labelWithString: label), control])
    }

    /// A note under the control in the row above.
    @discardableResult
    func addNote(_ note: NSTextField) -> NSGridRow {
        let row = grid.addRow(with: [NSGridCell.emptyContentView, note])
        row.topPadding = -4
        row.bottomPadding = 6
        return row
    }

    static func note(_ text: String = "") -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = controlWidth
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func show(_ text: String, in note: NSTextField, warning: Bool = false) {
        note.stringValue = text
        note.textColor = warning ? .systemRed : .secondaryLabelColor
    }

    static func fixWidth(_ view: NSView, _ width: CGFloat = controlWidth) -> NSView {
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }

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
        return button
    }
}

// MARK: General

final class GeneralSettingsPane: SettingsPane {
    private var firstPopUp: NSPopUpButton?
    private var secondPopUp: NSPopUpButton?
    private let loginCheckbox = NSButton(checkboxWithTitle: "Open Trot at login", target: nil, action: nil)
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let accessibilityButton = NSButton(title: "Open System Settings…", target: nil, action: nil)

    init() { super.init(title: "General") }

    required init?(coder: NSCoder) { fatalError() }

    override func buildRows() {
        let first = Self.popUp(
            Language.allCases, title: \.displayName, selected: Settings.firstLanguage,
            target: self, action: #selector(firstChanged(_:))
        )
        firstPopUp = first
        addRow("Translate into:", first)
        addNote(Self.note("Text in any other language is translated into this one."))

        let second = Self.popUp(
            Language.allCases, title: \.displayName, selected: Settings.secondLanguage,
            target: self, action: #selector(secondChanged(_:))
        )
        secondPopUp = second
        addRow("And from it into:", second)
        addNote(Self.note("Text already in the first language goes here instead."))

        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginChanged(_:))
        addRow("Launch:", loginCheckbox)

        accessibilityButton.target = self
        accessibilityButton.action = #selector(openAccessibility(_:))
        let row = NSStackView(views: [accessibilityStatus, accessibilityButton])
        row.spacing = 8
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
        let trusted = Accessibility.isTrusted
        accessibilityStatus.stringValue = trusted ? "Allowed" : "Not allowed"
        accessibilityStatus.textColor = trusted ? .labelColor : .systemOrange
        accessibilityButton.isHidden = trusted
    }

    @objc private func firstChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let language = Language(rawValue: raw) else { return }
        Settings.firstLanguage = language
    }

    @objc private func secondChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let language = Language(rawValue: raw) else { return }
        Settings.secondLanguage = language
    }

    @objc private func loginChanged(_ sender: NSButton) {
        Settings.launchesAtLogin = sender.state == .on
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
    private let keyField = NSSecureTextField()
    private let modelField = NSTextField()
    private let serviceNote = SettingsPane.note()
    private let testButton = NSButton(title: "Test", target: nil, action: nil)
    private let testNote = SettingsPane.note()
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
        keyRow = addRow("API key:", Self.fixWidth(keyField))
        modelRow = addRow("Model:", Self.fixWidth(modelField))

        testButton.target = self
        testButton.action = #selector(test(_:))
        let row = NSStackView(views: [testButton, testNote])
        row.spacing = 8
        addRow("", row)
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
        servicePopUp?.selectItem(at: ServiceKind.allCases.firstIndex(of: kind) ?? 0)
        baseURLRow?.isHidden = !kind.hasBaseURL
        keyRow?.isHidden = !kind.needsKey
        modelRow?.isHidden = !kind.hasModel
        baseURLField.stringValue = Settings.baseURL(for: kind)
        baseURLField.placeholderString = kind.defaultBaseURL
        keyField.stringValue = Settings.apiKey(for: kind)
        modelField.stringValue = Settings.model(for: kind)
        modelField.placeholderString = kind.defaultModel
        testNote.stringValue = ""
        let note: String =
            switch kind {
            case .openAI: "Any chat completions API: OpenAI, DeepSeek, Qwen, Ollama. Streams the translation."
            case .claude: "Anthropic's Messages API, streamed. The base URL can point at a proxy."
            case .deepL: "A key ending in :fx uses the free API, any other the Pro API."
            case .google: "Uses the endpoint Google's web client uses. No key, but unofficial, so it may stop working."
            }
        Self.show(note, in: serviceNote)
    }

    @objc private func serviceChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let kind = ServiceKind(rawValue: raw) else { return }
        Settings.service = kind
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === baseURLField {
            Settings.setBaseURL(field.stringValue, for: kind)
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
        Self.show("Translating…", in: testNote)
        testButton.isEnabled = false
        testTask = Task { [weak self] in
            defer { self?.testButton.isEnabled = true }
            do {
                var result = ""
                for try await chunk in service.translate("The quick brown fox jumps over the lazy dog.", from: .english, to: Settings.firstLanguage) {
                    result += chunk
                }
                guard !Task.isCancelled, let self else { return }
                Self.show(result.trimmingCharacters(in: .whitespacesAndNewlines), in: testNote)
            } catch {
                guard !Task.isCancelled, let self else { return }
                Self.show(error.localizedDescription, in: testNote, warning: true)
            }
        }
    }
}

// MARK: Shortcuts

final class ShortcutsSettingsPane: SettingsPane {
    private var recorders: [HotKeyAction: ShortcutRecorder] = [:]
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
            let row = NSStackView(views: [recorder, reset])
            row.spacing = 8
            addRow(action.displayName.replacingOccurrences(of: "…", with: "") + ":", row)
            let note = Self.note()
            notes[action] = note
            noteRows[action] = addNote(note)
            recorders[action] = recorder
            showState(for: action)
        }
        addNote(Self.note("Click a shortcut, then press the keys. Delete clears it. Shortcuts work in every app."))
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
    /// whether another app holds the combination.
    private func showState(for action: HotKeyAction) {
        guard let note = notes[action] else { return }
        let id = UInt32((HotKeyAction.allCases.firstIndex(of: action) ?? 0) + 1)
        let taken = Settings.shortcut(for: action) != nil && !HotKeyCenter.shared.isRegistered(id: id)
        Self.show(taken ? "Another app holds this shortcut, so it won't work." : "", in: note, warning: true)
        noteRows[action]?.isHidden = !taken
    }
}
