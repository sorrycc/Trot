import AppKit
import Vision

/// Pick a screen region with the system crosshair, then read its text.
enum ScreenOCR {
    enum Failure: LocalizedError, Equatable {
        case noText
        case screenRecordingDenied
        case captureFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .noText: "No text found in the screenshot."
            case .screenRecordingDenied: "Allow Screen Recording for Trot in System Settings, then open Trot again."
            case .captureFailed(let status): "The screenshot failed (screencapture exited with \(status))."
            }
        }
    }

    /// Whether Screen Recording is granted. macOS answers for the time the
    /// app was opened, so a grant shows after Trot is opened again.
    static var isAllowed: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS to show its permission prompt, which also lists Trot
    /// under Screen Recording in System Settings.
    static func requestAccess() {
        CGRequestScreenCaptureAccess()
    }

    @MainActor
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// The screenshot the user drew, as a file for `recognize`, or nil when
    /// the capture was cancelled with Escape.
    @MainActor
    static func capture() async throws -> URL? {
        // Without the permission screencapture still runs, but the image
        // holds only the wallpaper, so the failure would look like no text.
        guard isAllowed else {
            requestAccess()
            throw Failure.screenRecordingDenied
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("trot-\(UUID().uuidString)").appendingPathExtension("png")
        let status = try await runScreencapture(to: file)
        guard FileManager.default.fileExists(atPath: file.path) else {
            // Escape leaves no file and exits 1; anything else is a failure.
            if status > 1 { throw Failure.captureFailed(status) }
            return nil
        }
        return file
    }

    /// Drops a capture that is no longer wanted.
    static func discard(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }

    /// The text in the screenshot, joined into paragraphs. The file is
    /// deleted afterwards.
    static func recognize(_ file: URL) async throws -> String {
        defer { discard(file) }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "ja", "ko", "en"].map { Locale.Language(identifier: $0) }
        let observations = try await request.perform(on: file)
        let text = joinLines(observations.compactMap { $0.topCandidates(1).first?.string })
        guard !text.isEmpty else { throw Failure.noText }
        return text
    }

    /// `screencapture -i` draws the selection UI and asks for Screen
    /// Recording on Trot's behalf the first time.
    private static func runScreencapture(to file: URL) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", "-t", "png", file.path]
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Lines of one paragraph become one line: Chinese and Japanese join
    /// directly, everything else, Korean included, with a space. A line
    /// ending in sentence punctuation keeps its break.
    static func joinLines(_ lines: [String]) -> String {
        var result = ""
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if result.isEmpty {
                result = trimmed
            } else if let last = result.last, ".!?。！？:：".contains(last) {
                result += "\n" + trimmed
            } else if joinsWithoutSpace(result.last) || joinsWithoutSpace(trimmed.first) {
                result += trimmed
            } else {
                result += " " + trimmed
            }
        }
        return result
    }

    /// Han, kana and CJK punctuation: scripts written without spaces.
    private static func joinsWithoutSpace(_ character: Character?) -> Bool {
        guard let scalar = character?.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x3000...0x303F, 0xFF00...0xFFEF: return true
        default: return false
        }
    }
}
