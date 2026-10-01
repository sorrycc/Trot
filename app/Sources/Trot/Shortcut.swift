import AppKit
import Carbon.HIToolbox

/// A key combination for a global hotkey, such as Option+D. Carbon registers
/// hotkeys by virtual key code, so the code travels with the character.
struct Shortcut: Equatable, Sendable {
    static let allowedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    /// The character the key types without modifiers, lowercase. Only for display.
    let key: String
    let keyCode: UInt32
    let modifiers: NSEvent.ModifierFlags

    init(key: String, keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.key = key.lowercased()
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.allowedModifiers)
    }

    /// The combination `event` types.
    init?(event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers, !key.isEmpty else { return nil }
        self.init(key: key, keyCode: UInt32(event.keyCode), modifiers: event.modifierFlags)
    }

    static func == (a: Shortcut, b: Shortcut) -> Bool {
        a.keyCode == b.keyCode && a.modifiers == b.modifiers
    }

    private static let modifierNames: [(NSEvent.ModifierFlags, name: String, symbol: String, carbon: Int)] = [
        (.control, "ctrl", "⌃", controlKey), (.option, "opt", "⌥", optionKey),
        (.shift, "shift", "⇧", shiftKey), (.command, "cmd", "⌘", cmdKey),
    ]

    /// The modifier mask Carbon takes.
    var carbonModifiers: UInt32 {
        Self.modifierNames.filter { modifiers.contains($0.0) }.reduce(0) { $0 | UInt32($1.carbon) }
    }

    /// A function key needs no modifier; anything else does, or the hotkey
    /// would swallow ordinary typing in every app.
    var isUsable: Bool {
        !modifiers.intersection([.control, .option, .command]).isEmpty || isFunctionKey
    }

    private var isFunctionKey: Bool {
        guard let scalar = key.unicodeScalars.first else { return false }
        return (NSF1FunctionKey...NSF35FunctionKey).contains(Int(scalar.value))
    }

    /// As stored in user defaults: `shift+opt+d@2`.
    var text: String {
        Self.modifierNames.filter { modifiers.contains($0.0) }.map { $0.name + "+" }.joined() + key + "@\(keyCode)"
    }

    init?(text: String) {
        // The key itself can be "@", so the separator is the last one.
        guard let at = text.lastIndex(of: "@"), let keyCode = UInt32(text[text.index(after: at)...]) else { return nil }
        var rest = text[..<at]
        var modifiers: NSEvent.ModifierFlags = []
        var matched = true
        while matched {
            matched = false
            for (flag, name, _, _) in Self.modifierNames where rest.hasPrefix(name + "+") {
                rest = rest.dropFirst(name.count + 1)
                modifiers.insert(flag)
                matched = true
            }
        }
        guard rest.count == 1 else { return nil }
        self.init(key: String(rest), keyCode: keyCode, modifiers: modifiers)
    }

    /// As menus show it: ⌥D.
    var displayString: String {
        Self.modifierNames.filter { modifiers.contains($0.0) }.map(\.symbol).joined() + keyName
    }

    private var keyName: String {
        guard let scalar = key.unicodeScalars.first else { return key }
        switch Int(scalar.value) {
        case NSUpArrowFunctionKey: return "↑"
        case NSDownArrowFunctionKey: return "↓"
        case NSLeftArrowFunctionKey: return "←"
        case NSRightArrowFunctionKey: return "→"
        case NSF1FunctionKey...NSF35FunctionKey: return "F\(Int(scalar.value) - NSF1FunctionKey + 1)"
        case 0x0D, 0x03: return "↩"
        case 0x09, 0x19: return "⇥"
        case 0x20: return "Space"
        case 0x08, 0x7F: return "⌫"
        case NSDeleteFunctionKey: return "⌦"
        default: return key.uppercased()
        }
    }
}

/// A button that records a shortcut: click it, then press the combination.
/// Escape cancels and Delete clears.
@MainActor
final class ShortcutRecorder: NSButton {
    var shortcut: Shortcut? { didSet { updateTitle() } }
    /// Called with the combination pressed, or nil for Delete.
    var onRecord: ((Shortcut?) -> Void)?

    private var isRecording = false { didSet { updateTitle() } }

    init() {
        super.init(frame: .zero)
        bezelStyle = .push
        target = self
        action = #selector(clicked(_:))
        widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    @objc private func clicked(_ sender: Any?) {
        isRecording.toggle()
        if isRecording { window?.makeFirstResponder(self) }
    }

    /// Takes Cmd combinations before the menu does.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        record(event)
    }

    private func record(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Shortcut.allowedModifiers)
        if modifiers.isEmpty, event.keyCode == 53 {  // Escape
            isRecording = false
            return
        }
        if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 {  // Delete, Forward Delete
            isRecording = false
            onRecord?(nil)
            return
        }
        guard let shortcut = Shortcut(event: event), shortcut.isUsable else { return }
        isRecording = false
        onRecord?(shortcut)
    }

    private func updateTitle() {
        title = isRecording ? "Type Shortcut…" : shortcut?.displayString ?? "None"
    }
}
