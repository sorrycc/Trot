import AppKit

/// Takes text from a selection, the input panel or a screenshot, picks the
/// target language and service, and streams the translation into the panel.
@MainActor
final class TranslateController {
    private let panel = TranslatePanel()
    private var task: Task<Void, Never>?
    /// Counts user actions, so work started for an earlier one, a selection
    /// read or a stream, can tell it was overtaken and stay away from the
    /// panel. A cancelled stream ends without throwing, so this is checked
    /// as well as cancellation.
    private var generation = 0
    /// The text being translated, for retranslating with another target or service.
    private var text = ""
    private var detected: Language?
    private var target: Language?

    init() {
        panel.onTranslate = { [weak self] text in self?.translate(text) }
        panel.onTargetChange = { [weak self] language in
            guard let self, let source = retranslationSource() else { return }
            translate(source, to: language)
        }
        panel.onServiceChange = { [weak self] kind in
            Settings.service = kind
            guard let self, let source = retranslationSource(), panel.mode == .result || !panel.resultText.isEmpty else { return }
            translate(source, to: target)
        }
        panel.onClose = { [weak self] in self?.stop() }
    }

    /// Ends the current translation and any pending read. Returns the new
    /// generation, for work that continues after an await.
    @discardableResult
    private func stop() -> Int {
        task?.cancel()
        task = nil
        generation &+= 1
        return generation
    }

    /// What the chip and the service picker retranslate: in input mode the
    /// field as it stands, else the text that was translated.
    private func retranslationSource() -> String? {
        let source = panel.mode == .input ? panel.sourceText.trimmingCharacters(in: .whitespacesAndNewlines) : text
        return source.isEmpty ? nil : source
    }

    /// The selection hotkey. Without the permission, or without a selection,
    /// the input panel opens instead so the key always does something.
    func translateSelection() {
        let point = NSEvent.mouseLocation
        guard Accessibility.isTrusted else {
            Accessibility.prompt()
            stop()
            panel.showInput(
                at: point, hint: "Allow Accessibility in System Settings to read selected text.",
                action: ("Open System Settings…", { Accessibility.openSystemSettings() })
            )
            return
        }
        // With the panel key, the selection is in the panel itself.
        if panel.isKeyWindow {
            if let selected = panel.selectedText {
                translate(selected, at: point)
            } else {
                stop()
                panel.showInput(at: point)
            }
            return
        }
        let run = stop()
        Task {
            let selected = await SelectionReader.read()
            guard generation == run else { return }
            if let selected {
                translate(selected, at: point)
            } else {
                panel.showInput(at: point, hint: "No text is selected. Type here instead.")
            }
        }
    }

    func showInput() {
        // Typing while a typed translation streams is fine; the result
        // belongs to the field. Anything else is a fresh start.
        if !(panel.mode == .input && panel.isVisible) { stop() }
        panel.showInput(at: NSEvent.mouseLocation)
    }

    func translateScreenshot() {
        let run = stop()
        Task {
            do {
                guard let recognized = try await ScreenOCR.capture() else { return }
                guard generation == run else { return }
                translate(recognized, at: NSEvent.mouseLocation)
            } catch let failure as ScreenOCR.Failure where failure == .screenRecordingDenied {
                guard generation == run else { return }
                panel.showInput(
                    at: NSEvent.mouseLocation, hint: failure.localizedDescription,
                    action: ("Open System Settings…", { ScreenOCR.openSystemSettings() })
                )
            } catch {
                guard generation == run else { return }
                panel.showInput(at: NSEvent.mouseLocation, hint: error.localizedDescription)
            }
        }
    }

    /// Translates `text`, into `target` when given, else by the two-language rule.
    func translate(_ text: String, to target: Language? = nil, at point: NSPoint? = nil) {
        let run = stop()
        let detected = Language.detect(text)
        let target = target ?? Settings.target(for: detected)
        self.text = text
        self.detected = detected
        self.target = target
        let kind = Settings.service
        let service = kind.makeService()
        if panel.mode == .input && panel.isVisible && point == nil {
            panel.setLanguages(detected: detected, target: target)
            panel.beginInInput(service: kind)
        } else {
            panel.begin(source: text, detected: detected, target: target, service: kind, at: point ?? NSEvent.mouseLocation)
        }
        let start = ContinuousClock.now
        task = Task { [weak self] in
            do {
                for try await chunk in service.translate(text, from: detected, to: target) {
                    guard let self, generation == run else { return }
                    panel.append(chunk)
                }
                guard let self, generation == run, !Task.isCancelled else { return }
                let elapsed = start.duration(to: .now)
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                panel.finish(status: "\(kind.shortName) · \(String(format: "%.1f", seconds)) s")
            } catch {
                guard let self, generation == run, !Task.isCancelled, panel.isVisible else { return }
                var action: (String, () -> Void)?
                if Self.needsSettings(error) {
                    action = ("Open Settings…", { (NSApp.delegate as? AppDelegate)?.showSettings(nil) })
                }
                panel.showError(error.localizedDescription, action: action)
            }
        }
    }

    /// Whether the error is one Settings can fix: a missing or rejected
    /// key, a wrong base URL.
    private static func needsSettings(_ error: Error) -> Bool {
        switch error as? TranslationError {
        case .missingKey, .badURL, .notAStream: true
        case .http(let code, _): code == 401 || code == 403 || code == 404
        default: false
        }
    }
}
