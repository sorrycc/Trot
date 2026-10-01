import AppKit
import ApplicationServices

/// The Accessibility permission, which reading another app's selection needs.
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to show its permission prompt, once per launch.
    @MainActor
    static func prompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
