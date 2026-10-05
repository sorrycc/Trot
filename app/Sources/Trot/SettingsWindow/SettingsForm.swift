import AppKit

/// A pane of grouped rows, laid out the way System Settings does it: a
/// title on the left, a control on the right, and related rows together in
/// a rounded box with an optional note under it. Every pane is the same
/// width, so switching panes moves nothing sideways.
@MainActor
class SettingsPane: NSViewController {
    static let paneWidth: CGFloat = 540
    static let inset: CGFloat = 20
    static let fieldWidth: CGFloat = 280
    static let popUpWidth: CGFloat = 200
    /// The width inside a group's box, between its paddings.
    static var rowWidth: CGFloat { paneWidth - inset * 2 - SettingsRow.padding * 2 }

    private let column = NSStackView()
    private var groups: [SettingsGroup] = []

    init(title: String) {
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = NSView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 18
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        // The window animates to the pane's height, and for those frames
        // the view is shorter or taller than its rows.
        let bottom = column.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Self.inset)
        bottom.priority = .defaultLow
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.paneWidth),
            column.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.inset),
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.inset),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.inset),
            bottom,
        ])
        self.view = view
        buildGroups()
        refresh()
    }

    /// Subclasses add their groups here.
    func buildGroups() {}

    @discardableResult
    func addGroup(_ rows: [SettingsRow], footer: NSView? = nil) -> SettingsGroup {
        let group = SettingsGroup(rows: rows, footer: footer)
        groups.append(group)
        column.addArrangedSubview(group)
        group.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return group
    }

    /// Call after showing or hiding a row or a note: draws the hairlines
    /// between the rows that are left and sizes the pane to them. The
    /// column is measured rather than the view, whose fitting size stays
    /// at its first value once rows are hidden.
    func refresh() {
        guard isViewLoaded else { return }
        groups.forEach { $0.refresh() }
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.paneWidth, height: ceil(column.fittingSize.height) + Self.inset * 2)
    }

    /// A small grey note that wraps, for under a group.
    static func note(_ text: String = "") -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = rowWidth
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func fixWidth<View: NSView>(_ view: View, _ width: CGFloat = fieldWidth) -> View {
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
        return fixWidth(button, popUpWidth)
    }
}

/// Related rows in one rounded box, a hairline between them, and an
/// optional note or link under the box.
@MainActor
final class SettingsGroup: NSStackView {
    private let rows: [SettingsRow]
    private let box = SettingsBox()

    init(rows: [SettingsRow], footer: NSView?) {
        self.rows = rows
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6

        let list = NSStackView(views: rows)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: box.topAnchor),
            list.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        for row in rows { row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        addArrangedSubview(box)
        box.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        if let footer {
            // In line with the row titles above it. A button's title sits
            // a little inside its frame.
            let inset = SettingsRow.padding - (footer is NSButton ? 3 : 0)
            let holder = NSView()
            footer.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(footer)
            NSLayoutConstraint.activate([
                footer.topAnchor.constraint(equalTo: holder.topAnchor),
                footer.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                footer.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: inset),
                footer.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -SettingsRow.padding),
            ])
            addArrangedSubview(holder)
            holder.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A hairline over every visible row but the first, and no box at all
    /// when every row is hidden.
    func refresh() {
        var first = true
        for row in rows where !row.isHidden {
            row.showsSeparator = !first
            first = false
        }
        isHidden = first
    }
}

/// The rounded, faintly filled background of a group.
private final class SettingsBox: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    /// Runs with the current appearance, so the fill follows light and dark.
    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.035).cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }
}

/// One setting: a title, an optional line of explanation under it, a
/// control on the right, and a note under them that comes and goes.
@MainActor
final class SettingsRow: NSView {
    enum NoteStyle {
        /// Grey, for saying what a value amounts to.
        case plain
        /// Red, for a value that won't work.
        case warning
        /// With a green tick or a red cross, for the result of a test.
        case success, failure
    }

    static let padding: CGFloat = 12

    private let separator = NSBox()
    private let noteIcon = NSImageView()
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let noteRow: NSStackView

    var showsSeparator = false { didSet { separator.isHidden = !showsSeparator } }

    /// `control` sits at the right edge. `subtitle` wraps within
    /// `subtitleWidth`, which leaves room for the control.
    init(_ title: String, subtitle: String? = nil, subtitleWidth: CGFloat = 260, control: NSView) {
        noteRow = NSStackView(views: [noteIcon, noteLabel])
        super.init(frame: .zero)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        let text = NSStackView(views: [titleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        if let subtitle {
            let label = NSTextField(wrappingLabelWithString: subtitle)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = subtitleWidth
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            text.addArrangedSubview(label)
        }
        // The spacer alone takes the slack: the text and the control both
        // hold to their own widths, which leaves the control at the right edge.
        text.setHuggingPriority(.init(600), for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        (control as? NSStackView)?.setHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let main = NSStackView(views: [text, spacer, control])
        main.alignment = .centerY
        main.spacing = 12

        noteIcon.setContentHuggingPriority(.required, for: .horizontal)
        noteLabel.font = .systemFont(ofSize: 11)
        // A service can answer with a page of error; the rest is in the tooltip.
        noteLabel.maximumNumberOfLines = 4
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noteRow.alignment = .firstBaseline
        noteRow.spacing = 5
        noteRow.isHidden = true

        let column = NSStackView(views: [main, noteRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.edgeInsets = NSEdgeInsets(top: 8, left: Self.padding, bottom: 8, right: Self.padding)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        separator.boxType = .separator
        separator.isHidden = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            main.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -Self.padding * 2),
            // Every row is at least as tall as one with a pop-up in it.
            main.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows `text` under the row, or takes the note away for nil or an
    /// empty string. The pane needs a `refresh()` afterwards.
    func setNote(_ text: String?, style: NoteStyle = .plain) {
        let text = text ?? ""
        noteRow.isHidden = text.isEmpty
        noteLabel.stringValue = text
        noteLabel.toolTip = text.isEmpty ? nil : text
        noteLabel.textColor = style == .warning ? .systemRed : style == .plain ? .secondaryLabelColor : .labelColor
        let symbol: (String, NSColor)? =
            switch style {
            case .success: ("checkmark.circle.fill", .systemGreen)
            case .failure: ("xmark.octagon.fill", .systemRed)
            case .plain, .warning: nil
            }
        noteIcon.isHidden = symbol == nil
        noteIcon.image = symbol.flatMap { NSImage(systemSymbolName: $0.0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        noteIcon.contentTintColor = symbol?.1
        noteLabel.preferredMaxLayoutWidth = SettingsPane.rowWidth - (symbol == nil ? 0 : 20)
    }
}

/// A coloured dot and a word for the state of a permission, and a button
/// to System Settings while it is missing.
@MainActor
final class PermissionStatus: NSStackView {
    private let dot = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let button: NSButton

    init(target: AnyObject, action: Selector) {
        button = NSButton(title: "Open System Settings…", target: target, action: action)
        super.init(frame: .zero)
        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .regular))
        label.textColor = .secondaryLabelColor
        button.controlSize = .small
        spacing = 5
        addArrangedSubview(dot)
        addArrangedSubview(label)
        addArrangedSubview(button)
        setCustomSpacing(10, after: label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(allowed: Bool) {
        label.stringValue = allowed ? "Allowed" : "Not allowed"
        dot.contentTintColor = allowed ? .systemGreen : .systemOrange
        button.isHidden = allowed
        setAccessibilityLabel(label.stringValue)
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
