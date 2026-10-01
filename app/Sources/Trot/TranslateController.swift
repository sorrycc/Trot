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

    /// Longer selections are cut here: no service takes a whole book in one
    /// request, and laying one out would hold up the panel.
    static let maxCharacters = 20_000
    /// A selection read that takes longer than this shows the panel with
    /// "Reading…", so the hotkey is seen to have done something.
    private static let readingDelay: Duration = .milliseconds(150)

    init() {
        panel.onTranslate = { [weak self] text in
            guard let self else { return }
            translate(text, to: panel.pickedTarget)
        }
        panel.onTargetChange = { [weak self] language in
            guard let self, let source = retranslationSource() else { return }
            translate(source, to: language)
        }
        panel.onServiceChange = { [weak self] kind in
            Settings.service = kind
            guard let self, let source = retranslationSource(),
                panel.mode == .result || !panel.resultText.isEmpty || panel.showsError
            else { return }
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
        HTTP.preconnect(to: Settings.service)
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
        panel.cancelStreaming()
        Task {
            // A slow read, as the pasteboard path in browsers can be, shows
            // the panel waiting. It takes no keys, so ⌘C still reaches the app.
            let waiting = Task {
                try? await Task.sleep(for: Self.readingDelay)
                guard !Task.isCancelled, generation == run else { return }
                panel.beginReading(status: "Reading the selection…", at: point, key: false)
            }
            let selected = await SelectionReader.read()
            waiting.cancel()
            guard generation == run else { return }
            if let selected {
                translate(selected, at: point)
            } else {
                panel.showInput(at: point, hint: "No text is selected. Type here instead.")
            }
        }
    }

    func showInput() {
        HTTP.preconnect(to: Settings.service)
        // Typing while a typed translation streams is fine; the result
        // belongs to the field. Anything else is a fresh start.
        if !(panel.mode == .input && panel.isVisible) { stop() }
        panel.showInput(at: NSEvent.mouseLocation)
    }

    func translateScreenshot() {
        let run = stop()
        HTTP.preconnect(to: Settings.service)
        Task {
            do {
                guard let file = try await ScreenOCR.capture() else {
                    // Escape in the crosshair: whatever was streaming is over.
                    if generation == run { panel.cancelStreaming() }
                    return
                }
                guard generation == run else { return }
                let point = NSEvent.mouseLocation
                panel.beginReading(status: "Reading the screenshot…", at: point)
                let recognized = try await ScreenOCR.recognize(file)
                guard generation == run else { return }
                translate(recognized, at: point)
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
        let (text, cut) = Self.capped(text)
        let detected = Language.detect(text, preferredChinese: Settings.preferredChinese)
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
                if panel.resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    panel.showError("\(kind.displayName) sent back an empty translation.", action: ("Retry", { [weak self] in self?.retry() }))
                    return
                }
                panel.finish(status: Self.status(for: kind, elapsed: start.duration(to: .now), cut: cut))
            } catch {
                guard let self, generation == run, !Task.isCancelled, panel.isVisible else { return }
                let action: (String, () -> Void) =
                    if Self.needsSettings(error, for: kind) {
                        ("Open Settings…", { (NSApp.delegate as? AppDelegate)?.showSettings(nil) })
                    } else {
                        ("Retry", { [weak self] in self?.retry() })
                    }
                panel.showError(error.localizedDescription, action: action)
            }
        }
    }

    /// Runs the last translation again, with the same target and whatever
    /// service is active now.
    private func retry() {
        guard let source = retranslationSource() else { return }
        translate(source, to: target)
    }

    /// `text` cut to `maxCharacters`, and whether it was.
    static func capped(_ text: String) -> (String, Bool) {
        guard text.count > maxCharacters else { return (text, false) }
        return (String(text.prefix(maxCharacters)), true)
    }

    /// The footer after a translation: the model when the service has one,
    /// the time it took, and a note when the text was cut.
    static func status(for kind: ServiceKind, elapsed: Duration, cut: Bool) -> String {
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        var parts: [String] = []
        if kind.hasModel { parts.append(kind.activeModel) }
        parts.append(String(format: "%.1f s", seconds))
        if cut { parts.append("first \(maxCharacters.formatted()) characters") }
        return parts.joined(separator: " · ")
    }

    /// Whether the error is one Settings can fix: a missing or rejected
    /// key, a wrong base URL. Google has nothing to set.
    static func needsSettings(_ error: Error, for kind: ServiceKind) -> Bool {
        guard kind != .google else { return false }
        switch error as? TranslationError {
        case .missingKey, .badURL, .notAStream: return true
        case .http(let code, _): return code == 401 || code == 403 || code == 404
        default: return false
        }
    }
}
