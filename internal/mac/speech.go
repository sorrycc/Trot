//go:build darwin

package mac

import (
	"sync"

	"github.com/ebitengine/purego/objc"
)

// Synthesizer reads text aloud with the system voice for a language. Use
// it on the main thread. OnEnd hears when an utterance it started ends,
// finished or stopped, on whatever thread AVFoundation tells it.
type Synthesizer struct {
	obj      id
	delegate id
	// current is the utterance playing now, so an end reported late for
	// the previous one doesn't mark this one as finished.
	current  id
	speaking bool
	OnEnd    func()
}

var (
	delegateOnce  sync.Once
	synthesizerMu sync.Mutex
	synthesizers  = map[id]*Synthesizer{} // by delegate
)

func delegateClass() id {
	delegateOnce.Do(func() {
		ended := func(self id, _ objc.SEL, _ id, utterance id) {
			synthesizerMu.Lock()
			s := synthesizers[self]
			synthesizerMu.Unlock()
			if s != nil {
				s.ended(utterance)
			}
		}
		_, err := objc.RegisterClass("TrotSpeechDelegate", objc.GetClass("NSObject"),
			[]*objc.Protocol{objc.GetProtocol("AVSpeechSynthesizerDelegate")}, nil,
			[]objc.MethodDef{
				{Cmd: sel("speechSynthesizer:didFinishSpeechUtterance:"), Fn: ended},
				{Cmd: sel("speechSynthesizer:didCancelSpeechUtterance:"), Fn: ended},
			})
		if err != nil {
			panic("trot: " + err.Error())
		}
	})
	return class("TrotSpeechDelegate")
}

// NewSynthesizer makes a synthesizer, which loads the system's voices.
func NewSynthesizer() *Synthesizer {
	s := &Synthesizer{}
	withPool(func() {
		s.obj = send(send(class("AVSpeechSynthesizer"), "alloc"), "init")
		s.delegate = send(send(delegateClass(), "alloc"), "init")
		send(s.obj, "setDelegate:", uintptr(s.delegate))
	})
	synthesizerMu.Lock()
	synthesizers[s.delegate] = s
	synthesizerMu.Unlock()
	return s
}

// Speak reads text in the voice of locale, such as "zh-CN", stopping
// what it read before.
func (s *Synthesizer) Speak(text, locale string) {
	if text == "" {
		return
	}
	withPool(func() {
		send(s.obj, "stopSpeakingAtBoundary:", 0)
		u := send(class("AVSpeechUtterance"), "speechUtteranceWithString:", uintptr(nsString(text)))
		if voice := send(class("AVSpeechSynthesisVoice"), "voiceWithLanguage:", uintptr(nsString(locale))); voice != 0 {
			send(u, "setVoice:", uintptr(voice))
		}
		synthesizerMu.Lock()
		if s.current != 0 {
			send(s.current, "release")
		}
		s.current = send(u, "retain")
		s.speaking = true
		synthesizerMu.Unlock()
		send(s.obj, "speakUtterance:", uintptr(u))
	})
}

// Stop stops reading.
func (s *Synthesizer) Stop() {
	synthesizerMu.Lock()
	if !s.speaking {
		synthesizerMu.Unlock()
		return
	}
	s.speaking = false
	cur := s.current
	s.current = 0
	synthesizerMu.Unlock()
	withPool(func() {
		send(s.obj, "stopSpeakingAtBoundary:", 0)
		if cur != 0 {
			send(cur, "release")
		}
	})
}

// Speaking reports whether it is reading.
func (s *Synthesizer) Speaking() bool {
	synthesizerMu.Lock()
	defer synthesizerMu.Unlock()
	return s.speaking
}

func (s *Synthesizer) ended(utterance id) {
	synthesizerMu.Lock()
	if utterance != s.current || s.current == 0 {
		synthesizerMu.Unlock()
		return
	}
	s.current = 0
	s.speaking = false
	fn := s.OnEnd
	synthesizerMu.Unlock()
	withPool(func() { send(utterance, "release") })
	if fn != nil {
		fn()
	}
}
