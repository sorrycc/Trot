import AVFoundation

/// Reads a translation aloud with the system voice for its language.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    var onChange: (() -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private(set) var isSpeaking = false { didSet { onChange?() } }
    /// The utterance playing now, so a cancel for the previous one that
    /// arrives late doesn't mark this one as finished.
    private var current: AVSpeechUtterance?
    /// Every utterance whose end hasn't been reported yet, held so that
    /// its identity can't be reused by a newer one in the meantime.
    private var inFlight: [AVSpeechUtterance] = []

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, in language: Language) {
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language.speechLocale)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        current = utterance
        inFlight.append(utterance)
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        guard isSpeaking else { return }
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    private func ended(_ utterance: ObjectIdentifier) {
        inFlight.removeAll { ObjectIdentifier($0) == utterance }
        guard let current, ObjectIdentifier(current) == utterance else { return }
        self.current = nil
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id) }
    }
}
