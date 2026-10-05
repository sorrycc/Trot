import AppKit

/// An error or a hint in place of the result: an icon, a message that
/// wraps, and an optional button under it, in a faintly tinted box.
@MainActor
final class NoticeView: NSView {
    enum Style {
        case error, hint

        var symbol: String { self == .error ? "exclamationmark.triangle.fill" : "info.circle.fill" }
        var tint: NSColor { self == .error ? .systemRed : .systemOrange }
    }

    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton()
    private var withButton: NSLayoutConstraint!
    private var withoutButton: NSLayoutConstraint!
    private var style = Style.hint { didSet { needsDisplay = true } }
    private var action: (() -> Void)?
    /// Counts changes to what is shown, since a new message can change
    /// the height without anything being hidden or shown.
    private(set) var revision: CGFloat = 0

    private static let padding: CGFloat = 10

    init(width: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous

        icon.setContentHuggingPriority(.required, for: .horizontal)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = width - Self.padding * 2 - 22
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [icon, label])
        row.alignment = .firstBaseline
        row.spacing = 6
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.target = self
        button.action = #selector(run(_:))

        for view in [row, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        withButton = button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding)
        withoutButton = row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.padding),
            button.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 8),
            // Under the message, not under the icon.
            button.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            withoutButton,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `returnPresses` makes Return press the button.
    func show(_ message: String, style: Style, action: (String, () -> Void)?, returnPresses: Bool) {
        self.style = style
        icon.image = NSImage(systemSymbolName: style.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        icon.contentTintColor = style.tint
        label.stringValue = message
        label.toolTip = message
        self.action = action?.1
        button.title = action?.0 ?? ""
        button.isHidden = action == nil
        button.keyEquivalent = returnPresses && action != nil ? "\r" : ""
        withoutButton.isActive = action == nil
        withButton.isActive = action != nil
        revision += 1
    }

    func clear() {
        action = nil
        button.keyEquivalent = ""
    }

    @objc private func run(_ sender: Any?) {
        action?()
    }

    override var wantsUpdateLayer: Bool { true }

    /// Runs with the current appearance, so the fill follows light and dark.
    override func updateLayer() {
        let fill = style == .error ? NSColor.systemRed.withAlphaComponent(0.12) : NSColor.labelColor.withAlphaComponent(0.06)
        layer?.backgroundColor = fill.cgColor
    }
}

/// A rounded, faintly filled background for a chip in the header, sized to
/// its content, a little stronger under the mouse and while its menu is up.
final class Pill: NSView {
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
    override var wantsUpdateLayer: Bool { true }

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

/// The accent-coloured bar after the last word of a streaming translation,
/// shaped like the system's insertion point.
final class StreamCaret: NSView {
    static let width: CGFloat = 2

    var isPulsing = false {
        didSet {
            guard isPulsing != oldValue else { return }
            layer?.removeAnimation(forKey: "pulse")
            guard isPulsing else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.15
            pulse.duration = 0.55
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(pulse, forKey: "pulse")
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.width / 2
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Where the caret goes after the last character of the text
    /// `layoutManager` lays out, in its container's coordinates: where an
    /// insertion point would be. That is on the left of right-to-left
    /// text, and on the new line after a line break. `font` gives the
    /// caret its height.
    static func frame(afterTextIn layoutManager: NSLayoutManager, font: NSFont, rightToLeft: Bool) -> NSRect? {
        guard let container = layoutManager.textContainers.first else { return nil }
        layoutManager.ensureLayout(for: container)
        var origin = NSPoint.zero
        let glyphs = layoutManager.numberOfGlyphs
        if glyphs == 0 || layoutManager.extraLineFragmentTextContainer != nil {
            // Empty, or ending in a line break: the line that has no glyphs
            // yet. Its used part starts where typing would, on the right
            // for Arabic.
            let line = layoutManager.extraLineFragmentUsedRect
            origin = NSPoint(x: line.minX, y: line.minY)
        } else {
            // Where typing would go on: not always beside the last glyph,
            // as a number or a name at the end of an Arabic sentence sits
            // to the right of where the sentence continues.
            let end = NSRange(location: layoutManager.textStorage?.length ?? 0, length: 0)
            var count = 0
            guard let rects = layoutManager.rectArray(forCharacterRange: end, withinSelectedCharacterRange: end, in: container, rectCount: &count),
                count > 0
            else { return nil }
            let last = glyphs - 1
            let line = layoutManager.lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
            let baseline = line.minY + layoutManager.location(forGlyphAt: last).y
            origin = NSPoint(x: rects[0].minX - (rightToLeft ? width : 0), y: baseline - font.ascender)
        }
        // A space at the end of a wrapped line hangs past the edge.
        origin.x = min(max(origin.x, 0), container.size.width - width)
        return NSRect(x: origin.x.rounded(), y: origin.y.rounded(), width: width, height: ceil(font.ascender - font.descender))
    }

    override var wantsUpdateLayer: Bool { true }

    /// Runs with the current appearance, so the bar follows the accent colour.
    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    }

    /// Clicks go to the text under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
