import AppKit
import AVFoundation

/// The floating glass card with the source text, the translation and a row
/// of controls. One instance lives for the whole run and is shown at the
/// mouse for each translation. In input mode the source is editable and
/// Return translates it.
@MainActor
final class TranslatePanel: NSPanel, NSTextViewDelegate {
    enum Mode { case result, input }

    /// Return in input mode, with the typed text.
    var onTranslate: ((String) -> Void)?
    /// A target picked from the language chip.
    var onTargetChange: ((Language) -> Void)?
    var onServiceChange: ((ServiceKind) -> Void)?
    /// The panel was closed by the user; the translation can stop.
    var onClose: (() -> Void)?

    static let width: CGFloat = 440
    /// `-preview YES` shows the panel without taking the keyboard, for
    /// looking at it from a script while working elsewhere.
    private static let previewOnly = UserDefaults.standard.bool(forKey: "preview")
    private static let inset: CGFloat = 14
    private static var textWidth: CGFloat { width - inset * 2 }
    /// How far the panel sits from the mouse.
    private static let mouseGap: CGFloat = 12

    private let glass = NSGlassEffectView()
    private let languageButton = NSButton()
    private let servicePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let pinButton = NSButton()
    private let sourceView: PanelTextView
    private let sourceScroll = NSScrollView()
    private var sourceHeight: NSLayoutConstraint!
    private let placeholder = NSTextField(labelWithString: "Type or paste text, then press Return")
    private let separator = NSBox()
    private let resultView: PanelTextView
    private let resultScroll = NSScrollView()
    private var resultHeight: NSLayoutConstraint!
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let speakButton = NSButton()
    private let copyButton = NSButton()
    /// A button next to an error, such as Open Settings.
    private let actionButton = NSButton()
    private var action: (() -> Void)?
    private var clickMonitor: Any?
    private var copiedResetTask: Task<Void, Never>?
    private let speaker = Speaker()

    private(set) var mode: Mode = .result
    private(set) var isPinned = false { didSet { showPinState() } }
    private var detected: Language?
    private var target: Language = Settings.firstLanguage

    /// The translation so far, without the streaming cursor.
    private(set) var resultText = ""
    private var isStreaming = false
    /// Chunks waiting for the next flush. Services send many small pieces;
    /// drawing each would cost more than it shows.
    private var pendingChunks = ""
    private var flushScheduled = false
    /// The footer shows an error, so an empty result area has nothing to say.
    private var showsError = false

    private static let sourceAttributes: [NSAttributedString.Key: Any] = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        return [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
    }()

    private static let resultAttributes: [NSAttributedString.Key: Any] = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        return [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
    }()

    private static let cursorAttributes: [NSAttributedString.Key: Any] = {
        var attributes = resultAttributes
        attributes[.foregroundColor] = NSColor.controlAccentColor
        return attributes
    }()

    private static let cursor = "▍"

    init() {
        sourceView = PanelTextView.make(width: Self.textWidth, attributes: Self.sourceAttributes)
        resultView = PanelTextView.make(width: Self.textWidth, attributes: Self.resultAttributes)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 160),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        build()
        speaker.onChange = { [weak self] in self?.showSpeakState() }
    }

    override var canBecomeKey: Bool { true }

    // MARK: Layout

    private func build() {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 12, left: Self.inset, bottom: 10, right: Self.inset)

        // Header: language chip, service picker, pin and close.
        languageButton.isBordered = false
        languageButton.font = .systemFont(ofSize: 11, weight: .medium)
        languageButton.contentTintColor = .secondaryLabelColor
        languageButton.imagePosition = .imageTrailing
        languageButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Choose language")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        languageButton.toolTip = "Translate into another language"
        languageButton.target = self
        languageButton.action = #selector(showLanguageMenu(_:))
        languageButton.setContentHuggingPriority(.required, for: .horizontal)

        servicePopUp.isBordered = false
        servicePopUp.controlSize = .small
        servicePopUp.font = .systemFont(ofSize: 11, weight: .medium)
        for kind in ServiceKind.allCases {
            servicePopUp.addItem(withTitle: kind.shortName)
            servicePopUp.lastItem?.representedObject = kind.rawValue
        }
        servicePopUp.target = self
        servicePopUp.action = #selector(serviceChanged(_:))
        servicePopUp.setContentHuggingPriority(.required, for: .horizontal)

        let closeButton = NSButton()
        for (button, symbol, tip, action) in [
            (pinButton, "pin", "Keep Open", #selector(togglePin(_:))),
            (closeButton, "xmark", "Close (Escape)", #selector(closePanel(_:))),
        ] {
            configure(button, symbol: symbol, tip: tip, action: action)
        }

        let header = NSStackView(views: [Pill(languageButton), NSView(), Pill(servicePopUp), pinButton, closeButton])
        header.spacing = 4
        header.setCustomSpacing(8, after: header.arrangedSubviews[2])

        // Source and result text, each in a scroll view sized to its text up to a cap.
        sourceView.delegate = self
        sourceView.onEscape = { [weak self] in self?.closePanel(nil) }
        resultView.onEscape = { [weak self] in self?.closePanel(nil) }
        resultView.isEditable = false
        resultView.copyText = { [weak self] in self?.resultText ?? "" }
        configure(sourceScroll, with: sourceView)
        configure(resultScroll, with: resultView)
        sourceHeight = sourceScroll.heightAnchor.constraint(equalToConstant: 20)
        resultHeight = resultScroll.heightAnchor.constraint(equalToConstant: 20)

        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        sourceScroll.addSubview(placeholder)

        separator.boxType = .separator

        // Footer: progress, status, speak and copy.
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(speakButton, symbol: "speaker.wave.2", tip: "Speak Translation", action: #selector(speakResult(_:)))
        configure(copyButton, symbol: "doc.on.doc", tip: "Copy Translation (⌘C)", action: #selector(copyResult(_:)))
        actionButton.bezelStyle = .accessoryBarAction
        actionButton.controlSize = .small
        actionButton.font = .systemFont(ofSize: 11, weight: .medium)
        actionButton.target = self
        actionButton.action = #selector(runAction(_:))
        actionButton.isHidden = true
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let footer = NSStackView(views: [spinner, statusLabel, actionButton, NSView(), speakButton, copyButton])
        footer.spacing = 6
        footer.setCustomSpacing(2, after: speakButton)

        for view in [header, sourceScroll, separator, resultScroll, footer] {
            column.addArrangedSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: Self.inset).isActive = true
            view.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Self.inset).isActive = true
        }
        NSLayoutConstraint.activate([
            sourceHeight, resultHeight,
            header.heightAnchor.constraint(equalToConstant: 22),
            placeholder.leadingAnchor.constraint(equalTo: sourceScroll.leadingAnchor),
            placeholder.topAnchor.constraint(equalTo: sourceScroll.topAnchor, constant: 1),
        ])

        glass.cornerRadius = 18
        glass.contentView = column
        glass.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: root.topAnchor),
            glass.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        contentView = root
        showPinState()
        showSpeakState()
    }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        button.toolTip = tip
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    private func configure(_ scroll: NSScrollView, with textView: NSTextView) {
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
    }

    // MARK: Showing

    /// Shows the source and clears the result, ready for `append`.
    func begin(source: String, detected: Language?, target: Language, service: ServiceKind, at point: NSPoint) {
        mode = .result
        self.detected = detected
        self.target = target
        setText(source, in: sourceView, attributes: Self.sourceAttributes)
        sourceView.isEditable = false
        placeholder.isHidden = true
        startResult(service: service)
        showLanguages()
        pinButton.isHidden = false
        setAction(nil)
        present(near: point)
        makeFirstResponder(resultView)
    }

    /// Opens with an editable source. `hint` goes in the footer, with
    /// `action` as a button after it.
    func showInput(at point: NSPoint, hint: String? = nil, action: (String, () -> Void)? = nil) {
        mode = .input
        detected = nil
        target = Settings.firstLanguage
        if !isVisible || sourceView.isEditable == false {
            setText("", in: sourceView, attributes: Self.sourceAttributes)
            clearResult()
        }
        sourceView.isEditable = true
        placeholder.isHidden = !sourceView.string.isEmpty
        showLanguages()
        selectService(Settings.service)
        setBusy(false)
        showStatus(hint ?? "Return translates, Shift-Return adds a line", color: hint == nil ? .tertiaryLabelColor : .systemOrange)
        statusLabel.toolTip = hint
        setAction(action)
        // Input mode stays open on outside clicks by itself; see the click monitor.
        pinButton.isHidden = true
        present(near: point)
        makeFirstResponder(sourceView)
    }

    /// Starts a translation of the typed text while staying in input mode.
    func beginInInput(service: ServiceKind) {
        startResult(service: service)
        setAction(nil)
        updateLayout()
    }

    /// Shows an error in the footer, with `action` as a button after it.
    func showError(_ message: String, action: (String, () -> Void)? = nil) {
        showsError = true
        endStreaming()
        showStatus(message, color: .systemRed)
        // Errors get room to be read; everything else stays one line.
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.preferredMaxLayoutWidth = Self.textWidth - (action == nil ? 0 : 150)
        statusLabel.toolTip = message
        setAction(action)
        updateLayout()
    }

    private func setAction(_ action: (String, () -> Void)?) {
        self.action = action?.1
        actionButton.title = action?.0 ?? ""
        actionButton.isHidden = action == nil
    }

    @objc private func runAction(_ sender: Any?) {
        action?()
    }

    /// The text selected in either text view, for the selection hotkey
    /// while the panel is key.
    var selectedText: String? {
        for view in [resultView, sourceView] {
            let range = view.selectedRange()
            guard range.length > 0, let text = (view.string as NSString?)?.substring(with: range) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    func append(_ chunk: String) {
        pendingChunks += chunk
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
            self?.flushChunks()
        }
    }

    /// The translation is complete. `status` goes in the footer.
    func finish(status: String) {
        flushChunks()
        endStreaming()
        showStatus(status, color: .secondaryLabelColor)
        statusLabel.toolTip = nil
        updateLayout()
        if mode == .input { sourceView.isEditable = true }
    }

    func setLanguages(detected: Language?, target: Language) {
        self.detected = detected
        self.target = target
        showLanguages()
    }

    var sourceText: String { sourceView.string }

    private func startResult(service: ServiceKind) {
        showsError = false
        clearResult()
        isStreaming = true
        selectService(service)
        setBusy(true)
        showStatus("Translating with \(service.shortName)…", color: .secondaryLabelColor)
        statusLabel.toolTip = nil
        renderResult()
    }

    private func clearResult() {
        speaker.stop()
        resultText = ""
        pendingChunks = ""
        isStreaming = false
        renderResult()
    }

    private func endStreaming() {
        isStreaming = false
        setBusy(false)
        renderResult()
    }

    /// Appends the pending chunks before the cursor, in place, so layout
    /// only runs for the new text. Follows the end when it was in view.
    private func flushChunks() {
        flushScheduled = false
        guard !pendingChunks.isEmpty, let storage = resultView.textStorage else { return }
        let clip = resultScroll.contentView
        let wasAtEnd = clip.bounds.maxY >= resultView.frame.maxY - 4
        let cursorLength = isStreaming ? (Self.cursor as NSString).length : 0
        storage.beginEditing()
        storage.insert(NSAttributedString(string: pendingChunks, attributes: Self.resultAttributes), at: max(storage.length - cursorLength, 0))
        storage.endEditing()
        resultText += pendingChunks
        pendingChunks = ""
        updateLayout()
        if wasAtEnd, resultView.frame.height > clip.bounds.height {
            resultView.scrollToEndOfDocument(nil)
        }
    }

    /// Draws the result with the cursor after it while streaming.
    private func renderResult() {
        let text = NSMutableAttributedString(string: resultText, attributes: Self.resultAttributes)
        if isStreaming { text.append(NSAttributedString(string: Self.cursor, attributes: Self.cursorAttributes)) }
        resultView.textStorage?.setAttributedString(text)
    }

    private func showStatus(_ text: String, color: NSColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
        statusLabel.maximumNumberOfLines = 1
        statusLabel.lineBreakMode = .byTruncatingTail
    }

    private func present(near point: NSPoint) {
        updateLayout()
        if isVisible {
            resizeKeepingTop()
            return
        }
        place(near: point)
        alphaValue = 0
        if Self.previewOnly { orderFrontRegardless() } else { makeKeyAndOrderFront(nil) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        installClickMonitor()
    }

    @objc private func closePanel(_ sender: Any?) {
        speaker.stop()
        orderOut(nil)
        removeClickMonitor()
        isPinned = false
        onClose?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closePanel(nil) } else { super.keyDown(with: event) }
    }

    /// Cmd+W closes, like a window.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "w" {
            closePanel(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Position and size

    /// The panel goes below and to the right of `point`, or above it when
    /// the screen ends too soon, and in any case within the screen.
    private func place(near point: NSPoint) {
        let size = fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: point.x + Self.mouseGap, y: point.y - Self.mouseGap - size.height)
        if origin.y < visible.minY + 8, point.y + Self.mouseGap + size.height <= visible.maxY - 8 {
            origin.y = point.y + Self.mouseGap
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func resizeKeepingTop() {
        let size = fittingSize
        var frame = frame
        guard frame.size != size else { return }
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        if let visible = screen?.visibleFrame, frame.minY < visible.minY + 8 {
            frame.origin.y = visible.minY + 8
        }
        setFrame(frame, display: true)
    }

    private var fittingSize: NSSize {
        contentView?.layoutSubtreeIfNeeded()
        let height = contentView?.fittingSize.height ?? 160
        return NSSize(width: Self.width, height: ceil(height))
    }

    /// Sizes each text view to its text, up to a share of the screen, hides
    /// the result area while there is nothing to show, and resizes the panel.
    private func updateLayout() {
        let room = (screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let before = (sourceHeight.constant, resultHeight.constant, resultScroll.isHidden, copyButton.isHidden, speakButton.isHidden, actionButton.isHidden)
        sourceHeight.constant = min(max(textHeight(sourceView), 20), mode == .input ? room * 0.3 : 110)
        resultHeight.constant = min(max(textHeight(resultView), 20), room * 0.5)
        let hasResult = isStreaming || !resultText.isEmpty
        let showResult = hasResult || (mode == .result && !showsError)
        separator.isHidden = !showResult
        resultScroll.isHidden = !showResult
        copyButton.isHidden = resultText.isEmpty
        speakButton.isHidden = resultText.isEmpty || isStreaming
        let after = (sourceHeight.constant, resultHeight.constant, resultScroll.isHidden, copyButton.isHidden, speakButton.isHidden, actionButton.isHidden)
        // Measuring the window forces a layout pass, so only when something moved.
        if isVisible, before != after { resizeKeepingTop() }
    }

    private func textHeight(_ textView: NSTextView) -> CGFloat {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return 20 }
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }

    private func setText(_ text: String, in textView: NSTextView, attributes: [NSAttributedString.Key: Any]) {
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        textView.typingAttributes = attributes
        textView.scroll(.zero)
    }

    // MARK: Controls

    /// A hidden spinner leaves no gap in the footer, unlike a stopped one.
    private func setBusy(_ busy: Bool) {
        spinner.isHidden = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func showLanguages() {
        let from = detected?.displayName ?? (mode == .input ? "Auto" : "Unknown")
        languageButton.title = "\(from) → \(target.displayName)"
    }

    private func selectService(_ kind: ServiceKind) {
        servicePopUp.selectItem(at: ServiceKind.allCases.firstIndex(of: kind) ?? 0)
    }

    private func showPinState() {
        pinButton.image = NSImage(systemSymbolName: isPinned ? "pin.fill" : "pin", accessibilityDescription: "Keep Open")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        pinButton.contentTintColor = isPinned ? .controlAccentColor : .secondaryLabelColor
        pinButton.toolTip = isPinned ? "Close when clicking elsewhere" : "Keep Open"
    }

    private func showSpeakState() {
        let speaking = speaker.isSpeaking
        speakButton.image = NSImage(systemSymbolName: speaking ? "stop.fill" : "speaker.wave.2", accessibilityDescription: "Speak")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        speakButton.contentTintColor = speaking ? .controlAccentColor : .secondaryLabelColor
        speakButton.toolTip = speaking ? "Stop Speaking" : "Speak Translation"
    }

    @objc private func togglePin(_ sender: Any?) {
        isPinned.toggle()
    }

    @objc private func showLanguageMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for language in Language.allCases {
            let item = menu.addItem(withTitle: language.displayName, action: #selector(targetPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            item.state = language == target ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 6), in: sender)
    }

    @objc private func targetPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let language = Language(rawValue: raw), language != target else { return }
        target = language
        showLanguages()
        onTargetChange?(language)
    }

    @objc private func serviceChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let kind = ServiceKind(rawValue: raw) else { return }
        onServiceChange?(kind)
    }

    @objc private func speakResult(_ sender: Any?) {
        if speaker.isSpeaking {
            speaker.stop()
        } else {
            speaker.speak(resultText, in: target)
        }
    }

    @objc private func copyResult(_ sender: Any?) {
        guard !resultText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        copyButton.contentTintColor = .systemGreen
        copiedResetTask?.cancel()
        copiedResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self else { return }
            copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy Translation")?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            copyButton.contentTintColor = .secondaryLabelColor
        }
    }

    /// Clicks in other apps close the panel unless it's pinned. Clicks in
    /// Trot's own windows never reach a global monitor.
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isPinned, self.mode != .input else { return }
                self.closePanel(nil)
            }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !sourceView.string.isEmpty
        updateLayout()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            guard mode == .input, !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false) else { return false }
            let text = sourceView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { onTranslate?(text) }
            return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            closePanel(nil)
            return true
        default:
            return false
        }
    }
}

/// A rounded, faintly filled background for a chip in the header, sized to
/// its content.
private final class Pill: NSView {
    init(_ content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Runs with the current appearance, so the fill follows light and dark.
    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
    }
}

/// A text view that closes the panel on Escape and copies all of its text
/// with Cmd+C when nothing is selected.
final class PanelTextView: NSTextView {
    var onEscape: (() -> Void)?
    /// What Cmd+C copies when nothing is selected. Defaults to the text.
    var copyText: (() -> String)?

    /// A TextKit 1 stack, whose layout manager reports the text height.
    static func make(width: CGFloat, attributes: [NSAttributedString.Key: Any]) -> PanelTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        // The column is a fixed width, so the container is too: measuring
        // then never depends on whether the views have been laid out.
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        let view = PanelTextView(frame: NSRect(x: 0, y: 0, width: width, height: 20), textContainer: container)
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.allowsUndo = true
        view.typingAttributes = attributes
        view.font = attributes[.font] as? NSFont
        view.textColor = attributes[.foregroundColor] as? NSColor
        view.insertionPointColor = .controlAccentColor
        return view
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func copy(_ sender: Any?) {
        guard selectedRange().length == 0 else { return super.copy(sender) }
        let text = copyText?() ?? string
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Reads a translation aloud with the system voice for its language.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    var onChange: (() -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private(set) var isSpeaking = false { didSet { onChange?() } }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, in language: Language) {
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language.speechLocale)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        guard isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
