import AppKit

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
            LinkButton(title: "Website", url: AppInfo.homepage),
            LinkButton(title: "Report a Problem", url: AppInfo.issues),
            LinkButton(title: "MIT License", url: AppInfo.license),
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
