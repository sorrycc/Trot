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
    /// The source box in result mode shows this much; the rest scrolls.
    private static let sourceCap: CGFloat = 110

    private let glass = NSGlassEffectView()
    /// Everything in the card, top to bottom. Pinned to the top of the
    /// glass only, so the window can animate to the column's height
    /// without a frame where the two disagree.
    private let column = NSStackView()
    private let languageButton = NSButton()
    private let servicePill: Pill
    private let serviceButton = NSButton()
    private let pinButton = NSButton()
    private let sourceView: PanelTextView
    private let sourceScroll = NSScrollView()
    private var sourceHeight: NSLayoutConstraint!
    private let placeholder = NSTextField(labelWithString: "Type or paste text to translate")
    private let separator = NSBox()
    private let resultView: PanelTextView
    private let resultScroll = NSScrollView()
    private var resultHeight: NSLayoutConstraint!
    /// An error or a hint, with an optional button, in place of the result.
    private let notice = NSStackView()
    private let noticeIcon = NSImageView()
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton()
    private var action: (() -> Void)?
    private let footer = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let speakButton = NSButton()
    private let copyButton = NSButton()
    private var clickMonitor: Any?
    private var copiedResetTask: Task<Void, Never>?
    /// Counts presentations, so a fade-out that ends after the panel was
    /// shown again leaves it on screen.
    private var presentation = 0
    private var blinkTimer: Timer?
    private var cursorVisible = true
    /// When the last chunk landed. The cursor stays solid while text is
    /// arriving and blinks only once the stream goes quiet.
    private var lastChunk = ContinuousClock.now
    /// How much smaller the card is as it fades in and out.
    private static let entranceScale: CGFloat = 0.97
    /// Made on the first use: the synthesizer loads voices, which the
    /// panel's first appearance has no need of.
    private var speaker: Speaker?
    /// The screen the panel was last placed on, for sizing to its height.
    private var layoutScreen: NSScreen?

    private(set) var mode: Mode = .result
    private(set) var isPinned = false { didSet { showPinState() } }
    private var detected: Language?
    private var target: Language = Settings.firstLanguage
    /// A target the user picked from the chip, kept for the next Return in
    /// input mode so the two-language rule doesn't take it back.
    private(set) var pickedTarget: Language?

    /// The translation so far, without the streaming cursor.
    private(set) var resultText = ""
    private(set) var isStreaming = false
    /// Chunks waiting for the next flush. Services send many small pieces;
    /// drawing each would cost more than it shows.
    private var pendingChunks = ""
    private var flushScheduled = false
    /// A notice replaces the result area, so an empty one has nothing to say.
    private(set) var showsError = false
    /// Waiting for the selection or a screenshot: only the header and the
    /// footer show, with what is being waited for.
    private var isReading = false

    private static let sourceAttributes: [NSAttributedString.Key: Any] = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        return [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
    }()

    /// Typed text is the main thing on screen, so it reads like the result.
    private static let inputAttributes: [NSAttributedString.Key: Any] = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        return [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
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
    private static let chipFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    init() {
        sourceView = PanelTextView.make(width: Self.textWidth, attributes: Self.sourceAttributes, nonContiguous: true)
        resultView = PanelTextView.make(width: Self.textWidth, attributes: Self.resultAttributes, nonContiguous: false)
        servicePill = Pill(serviceButton)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 160),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false
        )
        // Invisible on a borderless panel; names the window for VoiceOver.
        title = "Translation"
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
        NotificationCenter.default.addObserver(forName: .serviceDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectService(Settings.service) }
        }
    }

    override var canBecomeKey: Bool { true }

    // MARK: Layout

    private func build() {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 12, left: Self.inset, bottom: 12, right: Self.inset)

        // Header: language chip, service chip, pin and close. The chips
        // look alike: a value in label colour, a small chevron, a menu.
        for (button, tip, action) in [
            (languageButton, "Translate into another language (⌘L)", #selector(showLanguageMenu(_:))),
            (serviceButton, "Translation service (⌘1 – ⌘\(ServiceKind.allCases.count))", #selector(showServiceMenu(_:))),
        ] {
            button.isBordered = false
            button.imagePosition = .imageTrailing
            button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            button.contentTintColor = .tertiaryLabelColor
            button.toolTip = tip
            button.target = self
            button.action = action
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let closeButton = NSButton()
        for (button, symbol, tip, action) in [
            (pinButton, "pin", "Keep Open (⌘P)", #selector(togglePin(_:))),
            (closeButton, "xmark", "Close (Escape)", #selector(closePanel(_:))),
        ] {
            configure(button, symbol: symbol, tip: tip, action: action)
        }

        let header = NSStackView(views: [Pill(languageButton), NSView(), servicePill, pinButton, closeButton])
        header.spacing = 4
        header.setCustomSpacing(8, after: servicePill)

        // Source and result text, each in a scroll view sized to its text up to a cap.
        sourceView.delegate = self
        sourceView.onEscape = { [weak self] in self?.closePanel(nil) }
        resultView.onEscape = { [weak self] in self?.closePanel(nil) }
        resultView.isEditable = false
        resultView.onCopyAll = { [weak self] in self?.copyResult(nil) }
        configure(sourceScroll, with: sourceView)
        configure(resultScroll, with: resultView)
        sourceHeight = sourceScroll.heightAnchor.constraint(equalToConstant: 20)
        resultHeight = resultScroll.heightAnchor.constraint(equalToConstant: 20)

        placeholder.font = Self.inputAttributes[.font] as? NSFont
        placeholder.textColor = .placeholderTextColor
        placeholder.lineBreakMode = .byTruncatingTail
        placeholder.setContentCompressionResistancePriority(.required, for: .horizontal)
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        separator.boxType = .separator

        // The notice: an icon, a message that wraps, and a button under it.
        noticeIcon.setContentHuggingPriority(.required, for: .horizontal)
        noticeLabel.font = .systemFont(ofSize: 13)
        noticeLabel.textColor = .labelColor
        noticeLabel.preferredMaxLayoutWidth = Self.textWidth - 22
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let noticeRow = NSStackView(views: [noticeIcon, noticeLabel])
        noticeRow.alignment = .firstBaseline
        noticeRow.spacing = 6
        actionButton.bezelStyle = .accessoryBarAction
        actionButton.controlSize = .small
        actionButton.font = .systemFont(ofSize: 11, weight: .medium)
        actionButton.target = self
        actionButton.action = #selector(runAction(_:))
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        notice.orientation = .vertical
        notice.alignment = .leading
        notice.spacing = 8
        notice.addArrangedSubview(noticeRow)
        notice.addArrangedSubview(actionButton)
        notice.isHidden = true

        // Footer: status, speak and copy.
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(speakButton, symbol: "speaker.wave.2", tip: "Speak Translation", action: #selector(speakResult(_:)))
        configure(copyButton, symbol: "doc.on.doc", tip: "Copy Translation (⌘C)", action: #selector(copyResult(_:)))
        for view in [statusLabel, NSView(), speakButton, copyButton] { footer.addArrangedSubview(view) }
        footer.spacing = 6
        footer.setCustomSpacing(2, after: speakButton)

        for view in [header, sourceScroll, separator, resultScroll, notice, footer] {
            column.addArrangedSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: Self.inset).isActive = true
            view.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Self.inset).isActive = true
        }
        NSLayoutConstraint.activate([
            sourceHeight, resultHeight,
            header.heightAnchor.constraint(equalToConstant: 22),
            footer.heightAnchor.constraint(equalToConstant: 22),
        ])

        let host = NSView()
        host.addSubview(column)
        // Over the source box rather than in it: the scroll view lays out
        // its own subviews and would size the label itself.
        host.addSubview(placeholder)
        column.translatesAutoresizingMaskIntoConstraints = false
        // The column tells the window how tall to be; while the window
        // animates there, the host is shorter or taller than the column
        // for a few frames, which a required bottom constraint would fight.
        let bottom = column.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        bottom.priority = .defaultLow
        glass.cornerRadius = 18
        glass.contentView = host
        glass.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.wantsLayer = true
        root.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: root.topAnchor),
            glass.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: host.topAnchor),
            column.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bottom,
            column.widthAnchor.constraint(equalToConstant: Self.width),
            placeholder.leadingAnchor.constraint(equalTo: sourceScroll.leadingAnchor),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: sourceScroll.trailingAnchor),
            placeholder.topAnchor.constraint(equalTo: sourceScroll.topAnchor, constant: 1),
        ])
        contentView = root
        showPinState()
        showSpeakState()
        selectService(Settings.service)
    }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        // A bordered accessory button draws its rounded fill only under the
        // mouse, which is the hover state the icons need.
        button.isBordered = true
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = .imageOnly
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
        isReading = false
        pickedTarget = nil
        self.detected = detected
        self.target = target
        setText(source, in: sourceView, attributes: Self.sourceAttributes)
        sourceView.isEditable = false
        placeholder.isHidden = true
        startResult(service: service)
        showLanguages()
        pinButton.isHidden = false
        hideNotice()
        present(near: point)
        makeFirstResponder(resultView)
    }

    /// Shows only the header and `status`, while the selection or a
    /// screenshot is being read. `key` false leaves the keyboard with the
    /// app in front, which a synthesized ⌘C needs.
    func beginReading(status: String, at point: NSPoint, key: Bool = true) {
        mode = .result
        isReading = true
        detected = nil
        setText("", in: sourceView, attributes: Self.sourceAttributes)
        sourceView.isEditable = false
        placeholder.isHidden = true
        clearResult()
        showsError = false
        hideNotice()
        showLanguages()
        pinButton.isHidden = false
        showStatus(status)
        present(near: point, key: key)
    }

    /// Opens with an editable source. `hint` shows as a notice under it,
    /// with `action` as a button.
    func showInput(at point: NSPoint, hint: String? = nil, action: (String, () -> Void)? = nil) {
        let fresh = !isVisible || !sourceView.isEditable
        mode = .input
        isReading = false
        detected = nil
        if fresh {
            pickedTarget = nil
            target = Settings.firstLanguage
            setText("", in: sourceView, attributes: Self.inputAttributes)
            clearResult()
        }
        sourceView.isEditable = true
        sourceView.typingAttributes = Self.inputAttributes
        placeholder.isHidden = !sourceView.string.isEmpty
        showLanguages()
        showStatus("↩ Translate   ⇧↩ New line")
        if let hint {
            showNotice(hint, symbol: "info.circle.fill", tint: .systemOrange, action: action)
        } else {
            hideNotice()
        }
        // Input mode stays open on outside clicks by itself; see the click monitor.
        pinButton.isHidden = true
        present(near: point)
        makeFirstResponder(sourceView)
    }

    /// Starts a translation of the typed text while staying in input mode.
    /// The typed text steps back to source grey, so the result stands out.
    func beginInInput(service: ServiceKind) {
        applyAttributes(Self.sourceAttributes, to: sourceView)
        startResult(service: service)
        hideNotice()
        updateLayout()
    }

    /// Shows an error in place of the result, with `action` as a button
    /// under it. In result mode Return presses the button.
    func showError(_ message: String, action: (String, () -> Void)? = nil) {
        showsError = true
        isReading = false
        endStreaming()
        showStatus("")
        showNotice(message, symbol: "exclamationmark.triangle.fill", tint: .systemRed, action: action)
        announce(message)
        updateLayout()
    }

    /// The stream was stopped before it ended, by a newer action.
    func cancelStreaming() {
        guard isStreaming || isReading else { return }
        flushChunks()
        isReading = false
        endStreaming()
        showStatus("Stopped")
        updateLayout()
    }

    private func showNotice(_ message: String, symbol: String, tint: NSColor, action: (String, () -> Void)?) {
        noticeIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        noticeIcon.contentTintColor = tint
        noticeLabel.stringValue = message
        noticeLabel.toolTip = message
        self.action = action?.1
        actionButton.title = action?.0 ?? ""
        actionButton.isHidden = action == nil
        actionButton.keyEquivalent = mode == .result && action != nil ? "\r" : ""
        notice.isHidden = false
        updateLayout()
    }

    private func hideNotice() {
        guard !notice.isHidden else { return }
        notice.isHidden = true
        action = nil
        actionButton.keyEquivalent = ""
        updateLayout()
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
        showStatus(status)
        updateLayout()
        if mode == .input { sourceView.isEditable = true }
        announce(resultText)
    }

    func setLanguages(detected: Language?, target: Language) {
        self.detected = detected
        self.target = target
        showLanguages()
    }

    var sourceText: String { sourceView.string }

    private func startResult(service: ServiceKind) {
        showsError = false
        isReading = false
        clearResult()
        isStreaming = true
        lastChunk = .now
        selectService(service)
        showStatus("Translating…")
        renderResult()
        startBlinking()
    }

    /// The cursor blinks like an insertion point once the stream goes
    /// quiet, which says it is still alive. Only its colour changes, so no
    /// layout runs for the blink.
    private func startBlinking() {
        stopBlinking()
        cursorVisible = true
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.blink() }
        }
        blinkTimer?.tolerance = 0.1
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        cursorVisible = true
    }

    private func blink() {
        guard isStreaming, let storage = resultView.textStorage else { return }
        let length = (Self.cursor as NSString).length
        guard storage.length >= length else { return }
        let arriving = lastChunk.duration(to: .now) < .milliseconds(500)
        let visible = arriving ? true : !cursorVisible
        guard visible != cursorVisible else { return }
        cursorVisible = visible
        let color: NSColor = visible ? .controlAccentColor : .clear
        storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: storage.length - length, length: length))
    }

    private func clearResult() {
        speaker?.stop()
        stopBlinking()
        resultText = ""
        pendingChunks = ""
        isStreaming = false
        renderResult()
    }

    /// Ends the stream and drops the cursor in place, so a long result is
    /// not laid out again from the start.
    private func endStreaming() {
        let wasStreaming = isStreaming
        isStreaming = false
        stopBlinking()
        guard wasStreaming, let storage = resultView.textStorage else { return }
        let length = (Self.cursor as NSString).length
        guard storage.length >= length,
            storage.attributedSubstring(from: NSRange(location: storage.length - length, length: length)).string == Self.cursor
        else { return }
        storage.beginEditing()
        storage.deleteCharacters(in: NSRange(location: storage.length - length, length: length))
        storage.endEditing()
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
        lastChunk = .now
        if isStreaming, !cursorVisible { blink() }
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
        cursorVisible = true
    }

    private func showStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    /// Tells VoiceOver what just arrived; the text itself changes silently.
    private func announce(_ text: String) {
        guard !text.isEmpty, NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private func present(near point: NSPoint, key: Bool = true) {
        layoutScreen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        if isVisible {
            updateLayout()
            contentView?.layer?.removeAnimation(forKey: "exit")
            // Shown again during the fade-out: keep it, at full strength.
            if alphaValue < 1 {
                presentation &+= 1
                animator().alphaValue = 1
                installClickMonitor()
            }
            if key, !Self.previewOnly, !isKeyWindow { makeKeyAndOrderFront(nil) }
            return
        }
        updateLayout()
        place(near: point)
        presentation &+= 1
        alphaValue = 0
        if key, !Self.previewOnly { makeKeyAndOrderFront(nil) } else { orderFrontRegardless() }
        animateScale(from: Self.entranceScale, to: 1, duration: 0.2, key: "entrance")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        installClickMonitor()
    }

    /// The card grows from slightly smaller as it fades in, and shrinks
    /// as it fades out. The scale is a layer animation, so a resize while
    /// it runs, as an instant error causes, is not undone when it ends.
    private func animateScale(from: CGFloat, to: CGFloat, duration: TimeInterval, key: String) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            let content = contentView, let layer = content.layer
        else { return }
        let bounds = content.bounds
        func transform(_ scale: CGFloat) -> CATransform3D {
            var t = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
            t = CATransform3DScale(t, scale, scale, 1)
            return CATransform3DTranslate(t, -bounds.midX, -bounds.midY, 0)
        }
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: transform(from))
        scale.toValue = NSValue(caTransform3D: transform(to))
        scale.duration = duration
        scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        if to != 1 {
            scale.fillMode = .forwards
            scale.isRemovedOnCompletion = false
        }
        CATransaction.begin()
        // The window's shadow is cast for the full-size card; once the
        // card has grown into it, the shadow is drawn again to match.
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.invalidateShadow() }
        }
        layer.add(scale, forKey: key)
        CATransaction.commit()
    }

    @objc private func closePanel(_ sender: Any?) {
        speaker?.stop()
        stopBlinking()
        removeClickMonitor()
        isPinned = false
        onClose?()
        let run = presentation
        animateScale(from: 1, to: 0.98, duration: 0.12, key: "exit")
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.presentation == run else { return }
                self.orderOut(nil)
                self.contentView?.layer?.removeAnimation(forKey: "exit")
            }
        })
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closePanel(nil) } else { super.keyDown(with: event) }
    }

    /// ⌘W closes, like a window. ⌘P pins, ⌘L opens the language menu and
    /// ⌘1 to ⌘4 pick a service, so the panel works without the mouse.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, let key = event.charactersIgnoringModifiers {
            switch key {
            case "w":
                closePanel(nil)
                return true
            case "p" where !pinButton.isHidden:
                togglePin(nil)
                return true
            case "l":
                showLanguageMenu(languageButton)
                return true
            default:
                if let digit = Int(key), (1...ServiceKind.allCases.count).contains(digit) {
                    pick(ServiceKind.allCases[digit - 1])
                    return true
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Position and size

    /// The panel goes below and to the right of `point`, or above it when
    /// the screen ends too soon, and in any case within the screen.
    private func place(near point: NSPoint) {
        let size = fittingSize
        let visible = layoutScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: point.x + Self.mouseGap, y: point.y - Self.mouseGap - size.height)
        if origin.y < visible.minY + 8, point.y + Self.mouseGap + size.height <= visible.maxY - 8 {
            origin.y = point.y + Self.mouseGap
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrame(NSRect(origin: origin, size: size), display: false)
    }

    /// How long the card takes to grow to new text. Short enough that a
    /// stream of chunks reads as one motion, long enough to see.
    private static let growDuration: TimeInterval = 0.14

    /// Grows or shrinks the card to its content with the top edge still,
    /// animated, so text streaming in pushes the bottom down smoothly
    /// rather than in jumps. A new target during the animation retargets it.
    private func resizeKeepingTop() {
        let size = fittingSize
        var frame = frame
        guard frame.size != size else { return }
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        if let visible = (layoutScreen ?? screen)?.visibleFrame, frame.minY < visible.minY + 8 {
            frame.origin.y = visible.minY + 8
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.growDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(frame, display: true)
        }
    }

    private var fittingSize: NSSize {
        column.layoutSubtreeIfNeeded()
        return NSSize(width: Self.width, height: ceil(column.fittingSize.height))
    }

    /// Sizes each text view to its text, up to a share of the screen, shows
    /// the result area, the notice and the footer only when they have
    /// something to say, and resizes the panel.
    private func updateLayout() {
        let room = (layoutScreen ?? screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let sourceCap = mode == .input ? room * 0.3 : Self.sourceCap
        let resultCap = room * 0.5
        let before = layoutState
        sourceHeight.constant = min(max(textHeight(sourceView, cap: sourceCap), 20), sourceCap)
        // Once the result fills its box, more text only scrolls.
        if resultHeight.constant < resultCap || !isStreaming {
            resultHeight.constant = min(max(textHeight(resultView, cap: resultCap), 20), resultCap)
        }
        // A result that arrived before an error, as a cut-off one did, stays
        // in view with the notice under it.
        let hasResult = isStreaming || !resultText.isEmpty
        let showResult = !isReading && (hasResult || (mode == .result && !showsError))
        sourceScroll.isHidden = isReading
        separator.isHidden = !(showResult || (!notice.isHidden && !isReading))
        resultScroll.isHidden = !showResult
        copyButton.isHidden = resultText.isEmpty
        speakButton.isHidden = resultText.isEmpty || isStreaming
        footer.isHidden = statusLabel.stringValue.isEmpty && copyButton.isHidden && speakButton.isHidden
        let after = layoutState
        // Measuring the window forces a layout pass, so only when something moved.
        if isVisible, before != after { resizeKeepingTop() }
    }

    /// Everything that moves the card's height, for telling when it did.
    private var layoutState: [CGFloat] {
        [sourceHeight.constant, resultHeight.constant]
            + [resultScroll, footer, copyButton, speakButton, notice, actionButton, sourceScroll].map { $0.isHidden ? 1 : 0 }
    }

    /// The height of the text, measured only as far as `cap`: a long
    /// selection is laid out as far as the box shows, not to its end.
    private func textHeight(_ textView: NSTextView, cap: CGFloat) -> CGFloat {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return 20 }
        layoutManager.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: container.size.width, height: cap + 1), in: container)
        return min(ceil(layoutManager.usedRect(for: container).height), cap)
    }

    private func setText(_ text: String, in textView: NSTextView, attributes: [NSAttributedString.Key: Any]) {
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        textView.typingAttributes = attributes
        textView.scroll(.zero)
    }

    private func applyAttributes(_ attributes: [NSAttributedString.Key: Any], to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        textView.typingAttributes = attributes
    }

    // MARK: Controls

    /// The chip reads `English → 简体中文`, with the target in label colour
    /// so the destination stands out. With nothing detected it says Auto.
    private func showLanguages() {
        let from = detected?.displayName ?? "Auto"
        let title = NSMutableAttributedString(string: "\(from) → ", attributes: [
            .font: Self.chipFont, .foregroundColor: NSColor.secondaryLabelColor,
        ])
        title.append(NSAttributedString(string: target.displayName, attributes: [
            .font: Self.chipFont, .foregroundColor: NSColor.labelColor,
        ]))
        languageButton.attributedTitle = title
        languageButton.setAccessibilityLabel("Translate from \(from) into \(target.displayName)")
    }

    private func selectService(_ kind: ServiceKind) {
        serviceButton.attributedTitle = NSAttributedString(string: kind.shortName, attributes: [
            .font: Self.chipFont, .foregroundColor: NSColor.labelColor,
        ])
        serviceButton.setAccessibilityLabel("Service: \(kind.displayName)")
    }

    private func showPinState() {
        pinButton.image = NSImage(systemSymbolName: isPinned ? "pin.fill" : "pin", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        pinButton.contentTintColor = isPinned ? .controlAccentColor : .secondaryLabelColor
        let tip = isPinned ? "Close When Clicking Elsewhere (⌘P)" : "Keep Open (⌘P)"
        pinButton.toolTip = tip
        pinButton.setAccessibilityLabel(tip)
    }

    private func showSpeakState() {
        let speaking = speaker?.isSpeaking ?? false
        speakButton.image = NSImage(systemSymbolName: speaking ? "stop.fill" : "speaker.wave.2", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        speakButton.contentTintColor = speaking ? .controlAccentColor : .secondaryLabelColor
        let tip = speaking ? "Stop Speaking" : "Speak Translation"
        speakButton.toolTip = tip
        speakButton.setAccessibilityLabel(tip)
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
        popUp(menu, under: sender)
    }

    @objc private func showServiceMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for (index, kind) in ServiceKind.allCases.enumerated() {
            let item = menu.addItem(withTitle: kind.displayName, action: #selector(servicePicked(_:)), keyEquivalent: "\(index + 1)")
            item.target = self
            item.representedObject = kind.rawValue
            item.state = kind == Settings.service ? .on : .off
        }
        popUp(menu, under: sender)
    }

    private func popUp(_ menu: NSMenu, under button: NSButton) {
        (button.superview as? Pill)?.isPressed = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 6), in: button)
        (button.superview as? Pill)?.isPressed = false
    }

    @objc private func targetPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let language = Language(rawValue: raw), language != target else { return }
        target = language
        pickedTarget = language
        showLanguages()
        onTargetChange?(language)
    }

    @objc private func servicePicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = ServiceKind(rawValue: raw) else { return }
        pick(kind)
    }

    private func pick(_ kind: ServiceKind) {
        guard kind != Settings.service else { return }
        selectService(kind)
        onServiceChange?(kind)
    }

    @objc private func speakResult(_ sender: Any?) {
        if let speaker, speaker.isSpeaking {
            speaker.stop()
            return
        }
        let speaker = self.speaker ?? Speaker()
        if self.speaker == nil {
            speaker.onChange = { [weak self] in self?.showSpeakState() }
            self.speaker = speaker
        }
        speaker.speak(resultText, in: target)
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
            copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
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
        // Edited text is the next thing to translate, not the source of
        // the result below, so it reads as primary again.
        if mode == .input, (sourceView.typingAttributes[.font] as? NSFont) != (Self.inputAttributes[.font] as? NSFont) {
            applyAttributes(Self.inputAttributes, to: sourceView)
        }
        if !notice.isHidden, !showsError { hideNotice() }
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
/// its content, a little stronger under the mouse and while its menu is up.
private final class Pill: NSView {
    var isPressed = false { didSet { needsDisplay = true } }
    private var isHovered = false { didSet { needsDisplay = true } }

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
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Runs with the current appearance, so the fill follows light and dark.
    override func updateLayer() {
        let alpha: CGFloat = isPressed ? 0.16 : isHovered ? 0.12 : 0.07
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.allowsImplicitAnimation = true
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        }
    }
}

/// A text view that closes the panel on Escape and copies all of its text
/// with Cmd+C when nothing is selected.
final class PanelTextView: NSTextView {
    var onEscape: (() -> Void)?
    /// What Cmd+C does when nothing is selected. Defaults to copying the text.
    var onCopyAll: (() -> Void)?

    /// A TextKit 1 stack, whose layout manager reports the text height.
    /// `nonContiguous` lets a long text be laid out only as far as shown.
    static func make(width: CGFloat, attributes: [NSAttributedString.Key: Any], nonContiguous: Bool) -> PanelTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = nonContiguous
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
        if let onCopyAll { return onCopyAll() }
        guard !string.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// Reads a translation aloud with the system voice for its language.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    var onChange: (() -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private(set) var isSpeaking = false { didSet { onChange?() } }
    /// The utterance playing now, so a cancel for the previous one that
    /// arrives late doesn't mark this one as finished.
    private var current: AVSpeechUtterance?

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
        current = utterance
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        guard isSpeaking else { return }
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    private func ended(_ utterance: ObjectIdentifier) {
        guard let current, ObjectIdentifier(current) == utterance else { return }
        self.current = nil
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id) }
    }
}
