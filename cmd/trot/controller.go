package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/egoist/mygo"

	"trot/internal/lang"
	"trot/internal/mac"
	"trot/internal/ocr"
	"trot/internal/selection"
	"trot/internal/service"
	"trot/internal/settings"
)

const (
	// maxCharacters cuts longer selections: no service takes a whole book
	// in one request, and laying one out would hold up the panel.
	maxCharacters = 20_000
	// readingDelay: a selection read that takes longer shows the panel
	// with "Reading…", so the hotkey is seen to have done something.
	readingDelay = 150 * time.Millisecond
)

// controller takes text from a selection, the input panel or a
// screenshot, picks the target language and service, and streams the
// translation into the panel. It runs on the main thread; work that waits
// runs on goroutines and comes back through the panel's host.
type controller struct {
	s      *settings.Settings
	p      *panel
	reader *selection.Reader
	// cursor is where the mouse is.
	cursor func() mygo.Point
	// openSettings opens Settings, for errors it can fix.
	openSettings func()

	cancel context.CancelFunc
	// gen counts user actions, so work started for an earlier one, a
	// selection read or a stream, can tell it was overtaken and stay away
	// from the panel.
	gen int
	// text is what is being translated, for retranslating with another
	// target or service.
	text     string
	detected lang.Language
	target   lang.Language
}

func newController(s *settings.Settings, p *panel) *controller {
	t := &controller{s: s, p: p, reader: selection.New(), cursor: mygo.Screen.CursorScreenPoint}
	p.onTranslate = func(text string) { t.translate(text, p.picked, nil) }
	p.onTargetChange = func(l lang.Language) {
		if src := t.retranslationSource(); src != "" {
			t.translate(src, l, nil)
		}
	}
	p.onServiceChange = func(k service.Kind) {
		s.SetService(k)
		src := t.retranslationSource()
		if src != "" && (p.mode == modeResult || p.result != "" || p.showsError || p.streaming) {
			t.translate(src, t.target, nil)
		}
	}
	p.onClose = func() { t.stop(false) }
	return t
}

func (t *controller) post(fn func()) { t.p.host.update(fn) }

// stop ends the current translation and any pending read, and tells the
// panel so a stream in view ends rather than waiting for ever. It returns
// the new generation, for work that continues after waiting.
func (t *controller) stop(tellPanel bool) int {
	if t.cancel != nil {
		t.cancel()
		t.cancel = nil
	}
	t.gen++
	if tellPanel {
		t.p.cancelStreaming()
	}
	return t.gen
}

// retranslationSource is what the chip and the service picker translate
// again: in input mode the field as it stands, else the text that was
// translated. Nothing while the panel waits for new text.
func (t *controller) retranslationSource() string {
	if t.p.reading {
		return ""
	}
	if t.p.mode == modeInput {
		return strings.TrimSpace(t.p.source)
	}
	return t.text
}

func (t *controller) preconnect() {
	k := t.s.Service()
	service.Preconnect(k, t.s.Config(k))
}

// translateSelection is the selection hotkey. Without the permission, or
// without a selection, the input panel opens instead so the key always
// does something.
func (t *controller) translateSelection() {
	point := t.cursor()
	t.preconnect()
	if !mac.IsTrusted() {
		mac.PromptAccessibility()
		t.stop(true)
		t.p.showInput(point, "Allow Accessibility in System Settings to read selected text.",
			&action{"Open System Settings…", func() { mygo.Shell.OpenExternal(mac.AccessibilitySettingsURL) }})
		return
	}
	// With the panel key, the selection is in the panel itself.
	if t.p.host.key() {
		if sel := t.p.selectedText(); sel != "" {
			t.translate(sel, "", &point)
		} else {
			t.stop(true)
			t.p.showInput(point, "", nil)
		}
		return
	}
	run := t.stop(true)
	var once sync.Once
	done := make(chan struct{})
	// A slow read, as the pasteboard path in browsers can be, shows the
	// panel waiting. It takes no keys, so ⌘C still reaches the app.
	waiting := time.AfterFunc(readingDelay, func() {
		t.post(func() {
			select {
			case <-done:
				return
			default:
			}
			// A draft in the input panel is worth more than the notice.
			if t.gen != run || (t.p.mode == modeInput && t.p.host.visible()) {
				return
			}
			t.p.beginReading("Reading the selection…", point, false)
		})
	})
	go func() {
		text := t.reader.Read()
		t.post(func() {
			once.Do(func() { close(done) })
			waiting.Stop()
			if t.gen != run {
				return
			}
			if text != "" {
				t.translate(text, "", &point)
			} else {
				t.p.showInput(point, "No text is selected. Type here instead.", nil)
			}
		})
	}()
}

// showInput is the input hotkey.
func (t *controller) showInput() {
	t.preconnect()
	// Typing while a typed translation streams is fine; the result belongs
	// to the field. Anything else, a pending selection read included, is
	// a fresh start.
	if !(t.p.mode == modeInput && t.p.host.visible() && t.p.streaming) {
		t.stop(true)
	}
	t.p.showInput(t.cursor(), "", nil)
}

// translateScreenshot is the screenshot hotkey.
func (t *controller) translateScreenshot() {
	run := t.stop(true)
	// Out of the way of the crosshair.
	t.p.hide()
	t.preconnect()
	go func() {
		file, err := ocr.Capture(context.Background())
		t.post(func() {
			point := t.cursor()
			switch {
			case errors.Is(err, ocr.ErrDenied):
				if t.gen == run {
					t.p.showInput(point, err.Error(),
						&action{"Open System Settings…", func() { mygo.Shell.OpenExternal(mac.ScreenCaptureSettingsURL) }})
				}
				return
			case err != nil:
				if t.gen == run {
					t.p.showInput(point, err.Error(), nil)
				}
				return
			case file == "":
				return
			case t.gen != run:
				ocr.Discard(file)
				return
			}
			t.p.beginReading("Reading the screenshot…", point, true)
			go func() {
				text, err := ocr.Recognize(file)
				t.post(func() {
					if t.gen != run {
						return
					}
					if err != nil {
						t.p.showInput(point, err.Error(), nil)
						return
					}
					t.translate(text, "", &point)
				})
			}()
		})
	}()
}

// translate translates text, into target when given, else by the
// two-language rule. point places a panel that isn't showing.
func (t *controller) translate(text string, target lang.Language, point *mygo.Point) {
	run := t.stop(true)
	text, cut := capped(text)
	detected := lang.Detect(text, t.s.PreferredChinese())
	if target == "" {
		target = t.s.Target(detected)
	}
	t.text, t.detected, t.target = text, detected, target
	k := t.s.Service()
	cfg := t.s.Config(k)
	// The model as requested, not as Settings may say by the end.
	model := ""
	if k.HasModel() {
		model = cfg.Model
	}
	if t.p.mode == modeInput && t.p.host.visible() && point == nil {
		t.p.setLanguages(detected, target)
		t.p.beginInInput(k)
	} else {
		at := t.cursor()
		if point != nil {
			at = *point
		}
		t.p.begin(text, detected, target, k, at)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.cancel = cancel
	start := time.Now()
	s := &stream{t: t, run: run}
	go func() {
		err := service.Translate(ctx, k, cfg, text, detected, target, s.receive)
		t.post(func() {
			s.flush()
			if t.gen != run {
				return
			}
			if err != nil {
				if ctx.Err() != nil || !t.p.host.visible() {
					return
				}
				act := &action{"Retry", t.retry}
				if service.NeedsSettings(err, k) {
					act = &action{"Open Settings…", t.openSettings}
				}
				t.p.showError(service.Describe(err), act)
				return
			}
			// Counted here: the panel draws chunks a frame later, so its
			// text can still be empty when the stream ends.
			if strings.TrimSpace(s.received) == "" {
				t.p.showError(k.DisplayName()+" sent back an empty translation.", &action{"Retry", t.retry})
				return
			}
			t.p.finish(status(model, time.Since(start), cut))
		})
	}()
}

// stream gathers the pieces of a translation and hands them to the panel
// in batches: services send many small pieces, and drawing each would cost
// more than it shows.
type stream struct {
	t   *controller
	run int

	mu        sync.Mutex
	pending   string
	thinking  bool
	scheduled bool
	received  string // read once the stream ends
}

func (s *stream) receive(c service.Chunk) {
	s.mu.Lock()
	if c.Thinking {
		s.thinking = true
	} else {
		s.pending += c.Text
		s.received += c.Text
	}
	if s.scheduled {
		s.mu.Unlock()
		return
	}
	s.scheduled = true
	s.mu.Unlock()
	time.AfterFunc(16*time.Millisecond, func() { s.t.post(s.flush) })
}

// flush runs on the main thread.
func (s *stream) flush() {
	s.mu.Lock()
	pending, thinking := s.pending, s.thinking
	s.pending, s.thinking, s.scheduled = "", false, false
	s.mu.Unlock()
	if s.t.gen != s.run {
		return
	}
	if thinking {
		s.t.p.showThinking()
	}
	s.t.p.append(pending)
}

// retry runs the last translation again, with the same target and
// whatever service is active now.
func (t *controller) retry() {
	if src := t.retranslationSource(); src != "" {
		t.translate(src, t.target, nil)
	}
}

// capped is text cut to maxCharacters, and whether it was.
func capped(text string) (string, bool) {
	if utf8.RuneCountInString(text) <= maxCharacters {
		return text, false
	}
	n := 0
	for i := range text {
		if n == maxCharacters {
			return text[:i], true
		}
		n++
	}
	return text, false
}

// status is the footer after a translation: a note when the text was cut,
// the time it took, and the model when the service has one. The model
// comes last since a long name is cut at the end of the line.
func status(model string, elapsed time.Duration, cut bool) string {
	var parts []string
	if cut {
		parts = append(parts, "First 20,000 characters")
	}
	parts = append(parts, fmt.Sprintf("%.1f s", elapsed.Seconds()))
	if model != "" {
		parts = append(parts, model)
	}
	return strings.Join(parts, " · ")
}
