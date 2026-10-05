import AppKit

/// The active service, its base URL, key and model, and a test of them.
final class ServicesSettingsPane: SettingsPane, NSTextFieldDelegate {
    private var servicePopUp: NSPopUpButton?
    private let serviceNote = SettingsPane.note()
    private let baseURLField = NSTextField()
    private let keyField = NSSecureTextField()
    private let modelField = NSTextField()
    private var baseURLRow: SettingsRow?
    private var keyRow: SettingsRow?
    private var modelRow: SettingsRow?
    private let keyLink = LinkButton(title: "", url: "")
    private let testButton = NSButton(title: "Test", target: nil, action: nil)
    private let testSpinner = NSProgressIndicator()
    private var testRow: SettingsRow?
    private var testTask: Task<Void, Never>?

    private var kind: ServiceKind { Settings.service }

    init() { super.init(title: "Services") }

    required init?(coder: NSCoder) { fatalError() }

    override func buildGroups() {
        let popUp = Self.popUp(
            ServiceKind.allCases, title: \.displayName, selected: Settings.service,
            target: self, action: #selector(serviceChanged(_:))
        )
        servicePopUp = popUp
        addGroup([SettingsRow("Service", control: popUp)], footer: serviceNote)

        for field in [baseURLField, keyField, modelField] {
            field.delegate = self
            field.usesSingleLineMode = true
            field.cell?.isScrollable = true
        }
        let baseURL = SettingsRow("Base URL", control: Self.fixWidth(baseURLField))
        let key = SettingsRow("API key", control: Self.fixWidth(keyField))
        let model = SettingsRow("Model", control: Self.fixWidth(modelField))
        baseURLRow = baseURL
        keyRow = key
        modelRow = model
        addGroup([baseURL, key, model], footer: keyLink)

        testButton.target = self
        testButton.action = #selector(test(_:))
        testSpinner.style = .spinning
        testSpinner.controlSize = .small
        testSpinner.isDisplayedWhenStopped = false
        let control = NSStackView(views: [testSpinner, testButton])
        control.spacing = 8
        let test = SettingsRow("Test translation", subtitle: "Translates a sentence with these settings.", control: control)
        testRow = test
        addGroup([test])

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
        modelRow?.isHidden = !kind.hasModel
        if let page = kind.keyPage {
            keyLink.set(title: "Get an API key from \(kind.shortName)…", url: page)
        }
        keyLink.isHidden = kind.keyPage == nil
        baseURLField.stringValue = Settings.baseURL(for: kind)
        baseURLField.placeholderString = kind.defaultBaseURL
        keyField.stringValue = Settings.apiKey(for: kind)
        keyField.placeholderString = "Required"
        modelField.stringValue = Settings.model(for: kind)
        modelField.placeholderString = kind.defaultModel
        serviceNote.stringValue =
            switch kind {
            case .openAI: "Any chat completions API: OpenAI, DeepSeek, Qwen, Ollama. Streams the translation. Keys are stored on this Mac only."
            case .claude: "Anthropic's Messages API, streamed. The base URL can point at a proxy."
            case .deepL: "A key ending in :fx uses the free API, any other the Pro API."
            case .google: "Uses the endpoint Google's web client uses. No key, but unofficial, so it may stop working."
            }
        testRow?.setNote(nil)
        showBaseURLState()
    }

    /// Says what the typed base URL amounts to when that isn't obvious: a
    /// scheme added, an endpoint path dropped, or nothing usable at all.
    private func showBaseURLState() {
        let typed = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = ServiceKind.normalizedBaseURL(typed, for: kind)
        if typed.isEmpty {
            baseURLRow?.setNote(nil)
        } else if URL(string: normalized)?.host() == nil {
            baseURLRow?.setNote("Enter a URL such as \(kind.defaultBaseURL).", style: .warning)
        } else if normalized != typed {
            baseURLRow?.setNote("Requests go to \(normalized).")
        } else {
            baseURLRow?.setNote(nil)
        }
        refresh()
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
        showTest(nil)
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
                    showTest("\(kind.displayName) sent back an empty translation.", style: .failure)
                } else {
                    showTest(text, style: .success)
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                showTest(error.localizedDescription, style: .failure)
            }
        }
    }

    private func showTest(_ text: String?, style: SettingsRow.NoteStyle = .plain) {
        testRow?.setNote(text, style: style)
        refresh()
    }
}
