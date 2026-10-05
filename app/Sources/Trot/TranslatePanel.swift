import AppKit

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
    private static let inset: CGFloat = 16
    private static let cornerRadius: CGFloat = 18
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
    private let notice = NoticeView(width: textWidth)
    private let footer = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let speakButton = NSButton()
    private let copyButton = NSButton()
    private var clickMonitor: Any?
    private var copiedResetTask: Task<Void, Never>?
    /// Counts presentations, so a fade-out that ends after the panel was
    /// shown again leaves it on screen.
    private var presentation = 0
    /// Marks where the next words will land while a translation streams.
    private let caret = StreamCaret()
    /// Fires when the stream has gone quiet for a moment. The caret stays
    /// solid while text is arriving and pulses only then.
    private var quietTimer: Timer?
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

    /// The translation so far.
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
    private(set) var isReading = false
    /// The layout the window was last sized for, so any change since then
    /// resizes it, whoever made the change.
    private var appliedLayout: [CGFloat] = []

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

    private static let resultAttributes = resultAttributes(rightToLeft: false)
    private static let rightToLeftResultAttributes = resultAttributes(rightToLeft: true)

    /// Left to its own devices a paragraph starts on the side the system
    /// language does, so Arabic is told to start on the right.
    private static func resultAttributes(rightToLeft: Bool) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        if rightToLeft {
            style.baseWritingDirection = .rightToLeft
            style.alignment = .right
        }
        return [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
    }

    /// The attributes for the language the result is in.
    private var resultAttributes: [NSAttributedString.Key: Any] {
        target.isRightToLeft ? Self.rightToLeftResultAttributes : Self.resultAttributes
    }

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
        // In the text view, so it scrolls with the text it follows.
        resultView.addSubview(caret)
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
        glass.cornerRadius = Self.cornerRadius
        // Glass takes its brightness from what is behind it: a dark
        // card over a white page turns grey and the text fades. The tint
        // keeps the card its own colour and leaves a trace of the backdrop.
        glass.tintColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 0.12, alpha: 0.6) : NSColor(white: 1, alpha: 0.6)
        }
        glass.contentView = host
        glass.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.wantsLayer = true
        // The window's shadow and rim are cut from what the root layer
        // draws. Unmasked, that is the whole rectangle, and its square
        // corners show around the rounded card.
        root.layer?.cornerRadius = Self.cornerRadius
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
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
            // Clear of the insertion point, which blinks at the very edge.
            placeholder.leadingAnchor.constraint(equalTo: sourceScroll.leadingAnchor, constant: 2),
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
        showsError = false
        detected = nil
        if fresh {
            pickedTarget = nil
            target = Settings.firstLanguage
            setText("", in: sourceView, attributes: Self.inputAttributes)
            clearResult()
        } else {
            // Text left grey by its translation is the draft again.
            applyAttributes(Self.inputAttributes, to: sourceView)
        }
        sourceView.isEditable = true
        placeholder.isHidden = !sourceView.string.isEmpty
        showLanguages()
        showStatus("↩ Translate   ⇧↩ New line")
        if let hint {
            showNotice(hint, style: .hint, action: action)
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
        showNotice(message, style: .error, action: action)
        announce(message)
        updateLayout()
    }

    /// Takes the panel off the screen without a word to the owner, for
    /// when the owner is about to show it again or needs it out of the way.
    func hide() {
        guard isVisible else { return }
        isReading = false
        dismiss(notifying: false)
    }

    /// The stream was stopped before it ended, by a newer action. What
    /// arrived stays; a panel still waiting for its text has nothing to
    /// keep and goes away.
    func cancelStreaming() {
        if isReading {
            isReading = false
            dismiss(notifying: false)
            return
        }
        guard isStreaming else { return }
        flushChunks()
        endStreaming()
        showStatus("Stopped")
        updateLayout()
    }

    /// In result mode Return presses the notice's button; in input mode
    /// Return belongs to the field.
    private func showNotice(_ message: String, style: NoticeView.Style, action: (String, () -> Void)?) {
        notice.show(message, style: style, action: action, returnPresses: mode == .result)
        notice.isHidden = false
        updateLayout()
    }

    private func hideNotice() {
        guard !notice.isHidden else { return }
        notice.isHidden = true
        notice.clear()
        updateLayout()
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
        selectService(service)
        showStatus("Translating…")
        // Pulsing from the start: nothing has arrived yet.
        placeCaret()
        caret.isHidden = false
        caret.isPulsing = true
    }

    /// The caret pulses like an insertion point once the stream goes
    /// quiet, which says it is still alive. The pulse is a layer
    /// animation, so no layout or drawing runs for it.
    private func holdCaret() {
        caret.isPulsing = false
        quietTimer?.invalidate()
        quietTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isStreaming else { return }
                self.caret.isPulsing = true
            }
        }
    }

    private func hideCaret() {
        quietTimer?.invalidate()
        quietTimer = nil
        caret.isPulsing = false
        caret.isHidden = true
    }

    private func placeCaret() {
        guard let layoutManager = resultView.layoutManager, let font = resultAttributes[.font] as? NSFont else { return }
        if let frame = StreamCaret.frame(afterTextIn: layoutManager, font: font, rightToLeft: target.isRightToLeft) {
            caret.frame = frame
        }
    }

    private func clearResult() {
        speaker?.stop()
        hideCaret()
        resultText = ""
        pendingChunks = ""
        isStreaming = false
        setText("", in: resultView, attributes: resultAttributes)
        // A box left at its cap by a long result would stay there for the
        // next stream, which skips measuring once the box is full.
        resultHeight.constant = 20
    }

    /// Ends the stream. The caret is a view over the text, so taking it
    /// away leaves the text and its layout as they are.
    private func endStreaming() {
        isStreaming = false
        hideCaret()
    }

    /// Appends the pending chunks in place, so layout only runs for the
    /// new text. Follows the end when it was in view.
    private func flushChunks() {
        flushScheduled = false
        guard !pendingChunks.isEmpty, let storage = resultView.textStorage else { return }
        let clip = resultScroll.contentView
        let wasAtEnd = clip.bounds.maxY >= resultView.frame.maxY - 4
        storage.beginEditing()
        storage.append(NSAttributedString(string: pendingChunks, attributes: resultAttributes))
        storage.endEditing()
        resultText += pendingChunks
        pendingChunks = ""
        updateLayout()
        if isStreaming {
            placeCaret()
            holdCaret()
        }
        if wasAtEnd, resultView.frame.height > clip.bounds.height {
            resultView.scrollToEndOfDocument(nil)
        }
    }

    private func showStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.toolTip = text.isEmpty ? nil : text
    }

    /// Tells VoiceOver what just arrived; the text itself changes silently.
    private func announce(_ text: String) {
        guard !text.isEmpty, NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private func present(near point: NSPoint, key: Bool = true) {
        if isVisible {
            // The panel stays where it is, so it is sized for that screen.
            layoutScreen = screen
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
        layoutScreen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
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
        dismiss(notifying: true)
    }

    /// Fades the panel out. `notifying` tells the owner, which stops the
    /// translation; a close the owner asked for skips that.
    private func dismiss(notifying: Bool) {
        speaker?.stop()
        // The owner stops the request; the panel's side of it ends here,
        // or a panel shown again mid-fade would still count as streaming.
        endStreaming()
        removeClickMonitor()
        isPinned = false
        if notifying { onClose?() }
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

    /// Escape arrives here when a control other than the text views has
    /// the keyboard. A borderless panel has no close button to press.
    override func cancelOperation(_ sender: Any?) {
        closePanel(nil)
    }

    /// ⌘W closes, like a window. ⌘P pins, ⌘L opens the language menu and
    /// ⌘1 to ⌘4 pick a service, so the panel works without the mouse.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command, let key = event.charactersIgnoringModifiers {
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
        appliedLayout = layoutState
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
        // Measuring the window forces a layout pass, so only when something
        // moved since the window was last sized.
        let state = layoutState
        guard isVisible, state != appliedLayout else { return }
        appliedLayout = state
        resizeKeepingTop()
    }

    /// Everything that moves the card's height, for telling when it did.
    private var layoutState: [CGFloat] {
        [sourceHeight.constant, resultHeight.constant]
            + [resultScroll, footer, copyButton, speakButton, notice, sourceScroll, separator].map { $0.isHidden ? 1 : 0 }
            + [notice.revision]
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
        guard let raw = sender.representedObject as? String, let language = Language(rawValue: raw) else { return }
        // Picking the target already shown still pins it for the next Return.
        pickedTarget = language
        guard language != target else { return }
        target = language
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
        // A preview is looked at from a script while the mouse works elsewhere.
        guard clickMonitor == nil, !Self.previewOnly else { return }
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
