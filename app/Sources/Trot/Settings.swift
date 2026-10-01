import Foundation
import ServiceManagement

/// Every setting the Settings window shows, in the app's user defaults.
/// API keys are there too: the keychain would ask for permission after
/// every rebuild, since an ad-hoc signed app has a new identity each time.
enum Settings {
    static var defaults: UserDefaults { .standard }

    /// The language most text gets translated into.
    static var firstLanguage: Language {
        get { defaults.string(forKey: "firstLanguage").flatMap(Language.init) ?? .chineseSimplified }
        set { defaults.set(newValue.rawValue, forKey: "firstLanguage") }
    }

    /// Where text already in the first language goes.
    static var secondLanguage: Language {
        get { defaults.string(forKey: "secondLanguage").flatMap(Language.init) ?? .english }
        set { defaults.set(newValue.rawValue, forKey: "secondLanguage") }
    }

    /// Sets both languages. Picking one that the other already is swaps
    /// them, so the rule always has two places to go.
    static func setLanguages(first: Language, second: Language) {
        let (first, second) = resolved(first: first, second: second, before: (firstLanguage, secondLanguage))
        firstLanguage = first
        secondLanguage = second
    }

    /// `first` and `second` as `setLanguages` stores them: when the new
    /// pair is one language twice, the one that moved takes its place and
    /// the other steps over to where it was.
    static func resolved(first: Language, second: Language, before: (Language, Language)) -> (Language, Language) {
        guard first == second else { return (first, second) }
        return first == before.0 ? (before.1, second) : (first, before.0)
    }

    /// The Chinese the user reads, for text that could be either script.
    static var preferredChinese: Language {
        for language in [firstLanguage, secondLanguage] where language.sameFamily(as: .chineseSimplified) {
            return language
        }
        return .chineseSimplified
    }

    /// The target for `text` under the two-language rule.
    static func target(for detected: Language?) -> Language {
        guard let detected, detected.sameFamily(as: firstLanguage) else { return firstLanguage }
        return secondLanguage
    }

    static var service: ServiceKind {
        get { defaults.string(forKey: "service").flatMap(ServiceKind.init) ?? .openAI }
        set {
            defaults.set(newValue.rawValue, forKey: "service")
            NotificationCenter.default.post(name: .serviceDidChange, object: nil)
        }
    }

    /// As typed. Empty means the service's default.
    static func baseURL(for kind: ServiceKind) -> String {
        defaults.string(forKey: "service.\(kind.rawValue).baseURL") ?? ""
    }

    static func setBaseURL(_ url: String, for kind: ServiceKind) {
        set(url, key: "service.\(kind.rawValue).baseURL")
    }

    static func model(for kind: ServiceKind) -> String {
        defaults.string(forKey: "service.\(kind.rawValue).model") ?? ""
    }

    static func setModel(_ model: String, for kind: ServiceKind) {
        set(model, key: "service.\(kind.rawValue).model")
    }

    static func apiKey(for kind: ServiceKind) -> String {
        defaults.string(forKey: "service.\(kind.rawValue).apiKey") ?? ""
    }

    static func setAPIKey(_ key: String, for kind: ServiceKind) {
        set(key, key: "service.\(kind.rawValue).apiKey")
    }

    private static func set(_ value: String, key: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
    }

    // MARK: Shortcuts

    /// Stored as text like `opt+d@2`; unset means the default and empty means none.
    static func shortcut(for action: HotKeyAction) -> Shortcut? {
        guard let text = defaults.string(forKey: action.defaultsKey) else { return action.defaultShortcut }
        return Shortcut(text: text)
    }

    static func setShortcut(_ shortcut: Shortcut?, for action: HotKeyAction) {
        defaults.set(shortcut?.text ?? "", forKey: action.defaultsKey)
        NotificationCenter.default.post(name: .shortcutsDidChange, object: nil)
    }

    static func resetShortcut(for action: HotKeyAction) {
        defaults.removeObject(forKey: action.defaultsKey)
        NotificationCenter.default.post(name: .shortcutsDidChange, object: nil)
    }

    /// Whether the user changed or cleared the shortcut, so Reset has work to do.
    static func shortcutIsCustom(for action: HotKeyAction) -> Bool {
        defaults.object(forKey: action.defaultsKey) != nil
    }

    // MARK: Launch at login

    static var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// macOS registered the item but waits for the user to approve it.
    static var loginItemNeedsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setLaunchesAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// What a global hotkey does.
enum HotKeyAction: String, CaseIterable, Sendable {
    case translateSelection
    case translateInput
    case translateScreenshot

    var defaultsKey: String { "shortcut.\(rawValue)" }

    var displayName: String {
        switch self {
        case .translateSelection: "Translate Selection"
        case .translateInput: "Translate Input…"
        case .translateScreenshot: "Translate Screenshot…"
        }
    }

    /// Bob's defaults, so the fingers already know them.
    var defaultShortcut: Shortcut {
        switch self {
        case .translateSelection: Shortcut(key: "d", keyCode: 2, modifiers: [.option])
        case .translateInput: Shortcut(key: "a", keyCode: 0, modifiers: [.option])
        case .translateScreenshot: Shortcut(key: "s", keyCode: 1, modifiers: [.option])
        }
    }
}

/// Facts about the app itself, for About and the links in Settings.
enum AppInfo {
    static let homepage = "https://github.com/sorrycc/trot"
    static let issues = "https://github.com/sorrycc/trot/issues"
    static let license = "https://github.com/sorrycc/trot/blob/main/LICENSE"
    static let copyright = "© 2026 chencheng"
}

extension Notification.Name {
    static let serviceDidChange = Notification.Name("TrotServiceDidChange")
    static let shortcutsDidChange = Notification.Name("TrotShortcutsDidChange")
}
