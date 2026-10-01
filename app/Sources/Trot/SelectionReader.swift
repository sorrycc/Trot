import AppKit
import ApplicationServices

/// The text selected in the frontmost app.
///
/// Accessibility answers directly in native apps. Where it can't say, a
/// synthesized Cmd+C goes through the pasteboard, and the pasteboard is put
/// back afterwards. Before that, the app's Edit > Copy item is checked: when
/// it's disabled there is no selection, and nothing is copied.
enum SelectionReader {
    /// What Accessibility said about the focused element's selection.
    private enum AXAnswer {
        case text(String)
        /// The element has a selection attribute and it's empty.
        case empty
        /// The element doesn't expose a selection, as web views and Electron apps don't.
        case unavailable
    }

    /// Editors that copy the whole line when nothing is selected. A Cmd+C
    /// there would send a line the user never picked.
    private static let lineCopyingEditors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed", "com.sublimetext.4", "com.sublimetext.3", "com.github.atom",
    ]

    /// Electron editors mark a line copied without a selection in this
    /// pasteboard type, so such a copy can be undone and ignored.
    private static let vscodeEditorData = NSPasteboard.PasteboardType("vscode-editor-data")

    /// Only one read at a time: a second Cmd+C while the first is in flight
    /// would snapshot the first copy as the clipboard to restore.
    @MainActor private static var inFlight: Task<String?, Never>?
    /// Watches for a copy that lands after a read gave up, see `readThroughPasteboard`.
    @MainActor private static var lateCopyWatcher: Task<Void, Never>?

    @MainActor
    static func read() async -> String? {
        if let inFlight { return await inFlight.value }
        // A new read takes its own snapshot; the old watcher has nothing left to protect.
        lateCopyWatcher?.cancel()
        lateCopyWatcher = nil
        let task = Task<String?, Never> { await readOnce() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    @MainActor
    private static func readOnce() async -> String? {
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier ?? 0
        let bundle = app?.bundleIdentifier ?? ""
        let isLineCopyingEditor = lineCopyingEditors.contains(bundle)
        // Accessibility calls block until the app answers, so they run off
        // the main thread with a short timeout.
        var answer = await Task.detached(priority: .userInitiated) { readThroughAccessibility() }.value
        if case .unavailable = answer, isLineCopyingEditor, pid != 0 {
            // Electron builds its accessibility tree only when asked to.
            answer = await Task.detached(priority: .userInitiated) {
                enableManualAccessibility(pid: pid)
                return readThroughAccessibility()
            }.value
        }
        switch answer {
        case .text(let text):
            return text
        case .empty:
            if isLineCopyingEditor { return nil }
        case .unavailable:
            // Without a marker for an empty selection, a copy here could
            // be a whole line; only VS Code and Cursor set one.
            if isLineCopyingEditor, !bundle.hasPrefix("com.microsoft.VSCode"), bundle != "com.todesktop.230313mzl4w4u92" {
                return nil
            }
        }
        if pid != 0, await Task.detached(priority: .userInitiated, operation: { copyMenuItemEnabled(pid: pid) }).value == false {
            return nil
        }
        return await readThroughPasteboard(pid: pid)
    }

    private nonisolated static func readThroughAccessibility() -> AXAnswer {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused, let element = element(focused)
        else { return .unavailable }
        AXUIElementSetMessagingTimeout(element, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success else {
            return .unavailable
        }
        let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? .empty : .text(text)
    }

    private nonisolated static func enableManualAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Whether the app's Edit menu has an enabled ⌘C item, found by its key
    /// equivalent so menu titles in any language work. Nil when the menu
    /// can't be read.
    private nonisolated static func copyMenuItemEnabled(pid: pid_t) -> Bool? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let menuBar = element(attribute(app, kAXMenuBarAttribute)), let menus = children(menuBar) else { return nil }
        // The first menu is the application menu, which never has Copy.
        for menu in menus.dropFirst() {
            guard let submenus = children(menu) else { continue }
            for submenu in submenus {
                guard let items = children(submenu) else { continue }
                for item in items {
                    guard let key = attribute(item, kAXMenuItemCmdCharAttribute) as? String, key.uppercased() == "C",
                        (attribute(item, kAXMenuItemCmdModifiersAttribute) as? Int ?? 0) == 0
                    else { continue }
                    return (attribute(item, kAXEnabledAttribute) as? Bool) ?? true
                }
            }
        }
        return nil
    }

    private nonisolated static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private nonisolated static func children(_ parent: AXUIElement) -> [AXUIElement]? {
        (attribute(parent, kAXChildrenAttribute) as? [AnyObject])?.compactMap { element($0) }
    }

    /// `ref` as an element, when it is one. CF types don't support `as?`.
    private nonisolated static func element(_ ref: CFTypeRef?) -> AXUIElement? {
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(ref, to: AXUIElement.self)
    }

    // MARK: Pasteboard

    @MainActor
    private static func readThroughPasteboard(pid: pid_t) async -> String? {
        let pasteboard = NSPasteboard.general
        // Reading lazy types makes their app render them, which can take a
        // while for images, so this runs off the main thread with a budget.
        let saved = await Task.detached(priority: .userInitiated) { snapshot(NSPasteboard.general) }.value
        let before = pasteboard.changeCount
        postCopy()
        // Apps take a few ms to put the copy on the pasteboard, slow ones a few hundred.
        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(16))
            if pasteboard.changeCount != before { break }
        }
        guard pasteboard.changeCount != before else {
            // A copy landing after this point would replace the clipboard
            // for good, so keep watching a moment and put it back then.
            if let saved {
                lateCopyWatcher = Task { await restoreLateCopy(pasteboard, saved, before, pid: pid) }
            }
            return nil
        }
        let ours = pasteboard.changeCount
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let emptySelection = copiedFromEmptySelection(pasteboard)
        // Only undo the copy itself, never something written since. Without
        // a snapshot the copy stays, which beats a half-restored clipboard.
        if let saved, pasteboard.changeCount == ours { restore(pasteboard, saved) }
        if emptySelection { return nil }
        return text?.isEmpty == false ? text : nil
    }

    /// VS Code and Cursor copy the current line when nothing is selected and
    /// say so in their editor data.
    private static func copiedFromEmptySelection(_ pasteboard: NSPasteboard) -> Bool {
        guard let data = pasteboard.data(forType: vscodeEditorData),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["isFromEmptySelection"] as? Bool ?? false
    }

    @MainActor
    private static func restoreLateCopy(_ pasteboard: NSPasteboard, _ saved: Snapshot, _ before: Int, pid: pid_t) async {
        defer { lateCopyWatcher = nil }
        for _ in 0..<16 {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            if pasteboard.changeCount != before {
                // Only the copy we asked for, from the app we asked.
                let sameApp = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                if pasteboard.changeCount == before + 1, sameApp { restore(pasteboard, saved) }
                return
            }
        }
    }

    /// Cmd+C to the frontmost app. Only Command goes in the flags, so the
    /// hotkey's own modifiers, likely still held, don't ride along.
    private static func postCopy() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyC: CGKeyCode = 8
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    /// The pasteboard's items as data, skipping promised and dynamic types.
    /// Nil when the contents are too large or slow to copy, which means
    /// the clipboard won't be restored.
    private nonisolated static func snapshot(_ pasteboard: NSPasteboard) -> Snapshot? {
        let start = ContinuousClock.now
        var total = 0
        var items: Snapshot = []
        for item in pasteboard.pasteboardItems ?? [] {
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types where !type.rawValue.contains("promise") && !type.rawValue.hasPrefix("dyn.") {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if total > 32 << 20 || start.duration(to: .now) > .milliseconds(300) { return nil }
                entry[type] = data
            }
            items.append(entry)
        }
        return items
    }

    private static func restore(_ pasteboard: NSPasteboard, _ snapshot: Snapshot) {
        pasteboard.clearContents()
        let items = snapshot.filter { !$0.isEmpty }.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
