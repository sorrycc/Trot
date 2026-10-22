package main

import (
	"fmt"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"trot/internal/lang"
	"trot/internal/service"
	"trot/internal/settings"
)

// fakeHost stands in for the panel's window. Work posted from other
// goroutines waits in a queue for the test to run, as the main thread
// would.
type fakeHost struct {
	shown, keyed bool
	dismissed    int
	height       int
	queue        chan func()
}

func newFakeHost() *fakeHost { return &fakeHost{queue: make(chan func(), 256)} }

func (h *fakeHost) present(mygo.Point, bool)                  { h.shown = true }
func (h *fakeHost) dismiss()                                  { h.shown = false; h.dismissed++ }
func (h *fakeHost) fit(height int)                            { h.height = height }
func (h *fakeHost) visible() bool                             { return h.shown }
func (h *fakeHost) key() bool                                 { return h.keyed }
func (h *fakeHost) room() int                                 { return 900 }
func (h *fakeHost) popup(_ *mygo.Menu, _, _ int, done func()) { done() }
func (h *fakeHost) update(fn func())                          { h.queue <- fn }
func (h *fakeHost) reduceMotion() bool                        { return true }

// drain runs what was posted until cond holds.
func (h *fakeHost) drain(t *testing.T, tt *ui.Tester, cond func() bool) {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for !cond() {
		select {
		case fn := <-h.queue:
			fn()
			if tt != nil {
				tt.Frame()
			}
		case <-deadline:
			t.Fatal("timed out")
		}
	}
}

func testPanel(t *testing.T, overrides map[string]string) (*panel, *fakeHost, *ui.Tester) {
	t.Helper()
	s := settings.Load(filepath.Join(t.TempDir(), "settings.json"), overrides)
	p := newPanel(s)
	h := newFakeHost()
	p.host = h
	tt := ui.NewTester(p.view, panelWidth, 400)
	return p, h, tt
}

func TestResultShowsSourceTranslationAndFooter(t *testing.T) {
	p, h, tt := testPanel(t, nil)
	p.begin("Hello", lang.English, lang.ChineseSimplified, service.OpenAI, mygo.Point{})
	p.append("你")
	p.append("好")
	tt.Frame()
	if !h.shown || !tt.HasText("Hello") || !tt.HasText("Translating…") {
		t.Fatalf("texts %q", tt.Texts())
	}
	p.finish("1.2 s · gpt-4o-mini")
	tt.Frame()
	for _, want := range []string{"English → 简体中文", "OpenAI", "你好", "1.2 s · gpt-4o-mini"} {
		if !strings.Contains(strings.Join(tt.Texts(), "\n"), want) {
			t.Errorf("no %q in %q", want, tt.Texts())
		}
	}
	if h.height <= 0 {
		t.Error("the window was not fitted to the card")
	}
	if err := tt.Click("Copy Translation (⌘C)"); err != nil {
		t.Fatal(err)
	}
	if tt.Clipboard() != "你好" {
		t.Errorf("clipboard %q", tt.Clipboard())
	}
	// The translation is read out as it finishes, then the copy.
	if got := tt.Announcements(); len(got) < 2 || got[len(got)-2] != "你好" || got[len(got)-1] != "Copied" {
		t.Errorf("announcements %q", got)
	}
	if !tt.HasText("Copied") {
		t.Errorf("no Copied in %q", tt.Texts())
	}
}

func TestCmdCWithoutASelectionCopiesTheTranslation(t *testing.T) {
	p, _, tt := testPanel(t, nil)
	p.begin("Hello", lang.English, lang.ChineseSimplified, service.OpenAI, mygo.Point{})
	p.append("你好")
	p.finish("done")
	tt.Frame()
	tt.Key(ui.Cmd, ui.KeyC)
	if tt.Clipboard() != "你好" {
		t.Errorf("clipboard %q", tt.Clipboard())
	}
}

func TestTheGrowingCardFitsTheWindow(t *testing.T) {
	p, h, tt := testPanel(t, nil)
	p.begin("Hello", lang.English, lang.ChineseSimplified, service.OpenAI, mygo.Point{})
	tt.Frame()
	tt.Frame()
	short := h.height
	p.append(strings.Repeat("一段很长的翻译。", 40))
	tt.Frame()
	tt.Frame()
	if h.height <= short {
		t.Errorf("height %d after %d", h.height, short)
	}
}

func TestErrorWithActionAndReturn(t *testing.T) {
	p, _, tt := testPanel(t, nil)
	p.begin("Hello", lang.English, lang.ChineseSimplified, service.OpenAI, mygo.Point{})
	retried := 0
	p.showError("The API key was rejected (HTTP 401).", &action{"Open Settings…", func() { retried++ }})
	tt.Frame()
	if !tt.HasText("The API key was rejected (HTTP 401).") || !tt.HasText("Open Settings…") {
		t.Fatalf("texts %q", tt.Texts())
	}
	tt.Key(0, ui.KeyEnter)
	if retried != 1 {
		t.Errorf("Return pressed the button %d times", retried)
	}
	if tt.HasText("Translating…") {
		t.Error("the footer still says Translating")
	}
}

func TestInputModeTranslatesOnReturn(t *testing.T) {
	p, _, tt := testPanel(t, nil)
	var got []string
	p.onTranslate = func(text string) { got = append(got, text) }
	p.showInput(mygo.Point{}, "", nil)
	tt.Frame()
	if !tt.Focused("Text to translate") {
		t.Fatalf("the field lacks the keyboard: %q", tt.Texts())
	}
	tt.Type("hello")
	tt.Key(ui.Shift, ui.KeyEnter)
	tt.Type("world")
	tt.Key(0, ui.KeyEnter)
	if len(got) != 1 || got[0] != "hello\nworld" {
		t.Errorf("translated %q", got)
	}
}

// TestHintsGoAwayAsTheUserTypes: typing takes the hint away, which folds
// up as it fades, so the card closes up under it rather than jumping.
func TestHintsGoAwayAsTheUserTypes(t *testing.T) {
	p, h, tt := testPanel(t, nil)
	p.showInput(mygo.Point{}, "No text is selected. Type here instead.", nil)
	tt.Frame()
	tt.Frame()
	if !tt.HasText("No text is selected. Type here instead.") {
		t.Fatal("no hint")
	}
	tall := h.height
	tt.Type("x")
	tt.Frame()
	tt.Frame()
	if p.notice != nil {
		t.Error("the hint stayed")
	}
	folding := h.height
	time.Sleep(enterAnim.Duration + 100*time.Millisecond)
	tt.Frame()
	tt.Frame()
	if tt.HasText("No text is selected. Type here instead.") {
		t.Error("the hint stayed on screen")
	}
	if !(h.height < tall) || folding > tall {
		t.Errorf("the card went %d, %d, %d; want it to close up", tall, folding, h.height)
	}
	if testing.Short() {
		return
	}
	if !(folding > h.height) {
		t.Errorf("the card went from %d to %d at once; want it to fold up", tall, h.height)
	}
}

func TestShortcuts(t *testing.T) {
	p, h, tt := testPanel(t, nil)
	var picked service.Kind
	p.onServiceChange = func(k service.Kind) { picked = k }
	p.begin("Hello", lang.English, lang.ChineseSimplified, service.OpenAI, mygo.Point{})
	tt.Frame()
	tt.Key(ui.Cmd, ui.KeyP)
	if !p.pinned {
		t.Error("⌘P pins")
	}
	p.outsideClick()
	if !h.shown {
		t.Error("a pinned panel stays")
	}
	tt.Key(ui.Cmd, ui.KeyP)
	tt.Key(ui.Cmd, ui.Key4)
	if picked != service.DeepL {
		t.Errorf("⌘4 picked %q", picked)
	}
	tt.Key(ui.Cmd, ui.Key2)
	if picked != service.OpenAI {
		t.Errorf("⌘2 picked %q", picked)
	}
	closed := 0
	p.onClose = func() { closed++ }
	p.outsideClick()
	if h.shown || closed != 1 {
		t.Error("a click elsewhere closes an unpinned panel")
	}
}

func TestInputModeStaysOnOutsideClicks(t *testing.T) {
	p, h, _ := testPanel(t, nil)
	p.showInput(mygo.Point{}, "", nil)
	p.outsideClick()
	if !h.shown {
		t.Error("input mode closed")
	}
}

func TestReadingPanelGoesWhenCancelled(t *testing.T) {
	p, h, tt := testPanel(t, nil)
	p.beginReading("Reading the selection…", mygo.Point{}, false)
	tt.Frame()
	if !tt.HasText("Reading the selection…") || tt.HasText("Copy Translation (⌘C)") {
		t.Fatalf("texts %q", tt.Texts())
	}
	p.cancelStreaming()
	if h.shown {
		t.Error("a reading panel has nothing to keep")
	}
}

func TestStoppedStreamKeepsItsText(t *testing.T) {
	p, h, tt := testPanel(t, nil)
	p.begin("Hello", lang.English, lang.ChineseSimplified, service.OpenAI, mygo.Point{})
	p.append("半")
	p.cancelStreaming()
	tt.Frame()
	if !h.shown || !tt.HasText("Stopped") || p.streaming {
		t.Errorf("texts %q", tt.Texts())
	}
}

func TestABlankLineKeepsItsSpace(t *testing.T) {
	p, h, tt := testPanel(t, nil)
	p.begin("Hello", lang.English, lang.ChineseSimplified, service.OpenAI, mygo.Point{})
	p.append("一\n二")
	p.finish("done")
	tt.Frame()
	tight := h.height
	p.begin("Hello", lang.English, lang.ChineseSimplified, service.OpenAI, mygo.Point{})
	p.append("一\n\n二")
	p.finish("done")
	tt.Frame()
	tt.Frame()
	// A blank line adds a line's height between the two.
	if got := h.height - tight; got < lineStep-1 || got > lineStep+1 {
		t.Errorf("a blank line added %d DIPs, want %v", got, lineStep)
	}
	for _, want := range []string{"一", "二"} {
		if !tt.HasText(want) {
			t.Errorf("no %q in %q", want, tt.Texts())
		}
	}
}

func TestFlushDelayGrowsWithTheLine(t *testing.T) {
	if flushDelay(100) != 16*time.Millisecond || flushDelay(1000) != 33*time.Millisecond || flushDelay(5000) != 50*time.Millisecond {
		t.Errorf("delays %v %v %v", flushDelay(100), flushDelay(1000), flushDelay(5000))
	}
	s := &stream{scheduled: true}
	s.receive(service.Chunk{Text: "abc"})
	s.receive(service.Chunk{Text: "de\nfg"})
	if s.line != 2 {
		t.Errorf("line %d, want 2", s.line)
	}
	s.receive(service.Chunk{Text: "hij"})
	if s.line != 5 {
		t.Errorf("line %d, want 5", s.line)
	}
}

func TestAnErrorShakesAndSettles(t *testing.T) {
	if testing.Short() {
		t.Skip("waits for the animation")
	}
	p, _, tt := testPanel(t, nil)
	p.begin("Hello", lang.English, lang.ChineseSimplified, service.OpenAI, mygo.Point{})
	tt.Frame()
	time.Sleep(300 * time.Millisecond)
	tt.Frame()
	const msg = "The API key was rejected (HTTP 401)."
	shownAt := time.Now()
	p.showError(msg, nil)
	tt.Frame()
	start, _ := tt.Find(msg)
	// A busy machine can take the start of the shake to draw it.
	caught := time.Since(shownAt) < 50*time.Millisecond
	time.Sleep(time.Second)
	tt.Frame()
	end, _ := tt.Find(msg)
	if caught && start.X-end.X < 2 {
		t.Errorf("the error didn't start to the side: x %.1f, then %.1f", start.X, end.X)
	}
	// With Reduce Motion it is in place at once.
	p2, _, tt2 := testPanel(t, nil)
	tt2.SetPreferences(ui.Preferences{ReduceMotion: true})
	p2.begin("Hello", lang.English, lang.ChineseSimplified, service.OpenAI, mygo.Point{})
	p2.showError(msg, nil)
	tt2.Frame()
	still, _ := tt2.Find(msg)
	if d := still.X - end.X; d > 0.5 || d < -0.5 {
		t.Errorf("settled at x %.1f, without motion at %.1f", end.X, still.X)
	}
}

func TestAPinnedPanelsEdgeTakesTheAccent(t *testing.T) {
	if testing.Short() {
		t.Skip("waits for the animation")
	}
	p, _, tt := testPanel(t, nil)
	tt.SetSize(panelWidth, 160)
	p.begin("Hello", lang.English, lang.ChineseSimplified, service.OpenAI, mygo.Point{})
	p.append("你好")
	p.finish("done")
	tt.Frame()
	time.Sleep(300 * time.Millisecond)
	tt.Frame()
	before := tt.Image().RGBAAt(panelWidth/2, 0)
	tt.Key(ui.Cmd, ui.KeyP)
	tt.Frame()
	time.Sleep(400 * time.Millisecond)
	tt.Frame()
	after := tt.Image().RGBAAt(panelWidth/2, 0)
	if !p.pinned || after.B <= after.R || after == before {
		t.Errorf("edge %v, then %v pinned", before, after)
	}
}

func TestPlace(t *testing.T) {
	area := mygo.Rectangle{X: 0, Y: 25, Width: 1440, Height: 875}
	cases := []struct {
		point mygo.Point
		h     int
		x, y  int
	}{
		{mygo.Point{X: 100, Y: 100}, 200, 112, 112},
		// Near the bottom it goes above the mouse.
		{mygo.Point{X: 100, Y: 850}, 200, 112, 638},
		// Near the right edge it stays within the screen.
		{mygo.Point{X: 1400, Y: 100}, 200, 1440 - panelWidth - 8, 112},
		// Taller than the room: its bottom stays on the screen.
		{mygo.Point{X: 100, Y: 500}, 860, 112, 32},
	}
	for _, c := range cases {
		if x, y := place(c.point, panelWidth, c.h, area); x != c.x || y != c.y {
			t.Errorf("place(%v, %d) = %d, %d, want %d, %d", c.point, c.h, x, y, c.x, c.y)
		}
	}
}

func TestCapped(t *testing.T) {
	if s, cut := capped("hello"); s != "hello" || cut {
		t.Error("short text")
	}
	s, cut := capped(strings.Repeat("字", maxCharacters+10))
	if !cut || len([]rune(s)) != maxCharacters {
		t.Errorf("cut %v, %d runes", cut, len([]rune(s)))
	}
}

func TestStatus(t *testing.T) {
	if got := status("", 1250*time.Millisecond, false); got != "1.2 s" && got != "1.3 s" {
		t.Error(got)
	}
	if got := status("", 2*time.Second, true); !strings.HasPrefix(got, "First 20,000 characters · ") {
		t.Error(got)
	}
	if got := status("gpt-4o-mini", 2*time.Second, false); got != "2.0 s · gpt-4o-mini" {
		t.Error(got)
	}
}

// mockService streams a translation, or fails, as scripts/mock-service.py.
func mockService(t *testing.T) *httptest.Server {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/fail"):
			w.WriteHeader(401)
			w.Write([]byte(`{"error":{"message":"Incorrect API key"}}`))
		case strings.HasPrefix(r.URL.Path, "/empty"):
			w.Write([]byte("data: [DONE]\n\n"))
		default:
			for _, s := range []string{"你", "好"} {
				fmt.Fprintf(w, "data: {\"choices\":[{\"delta\":{\"content\":%q}}]}\n\n", s)
			}
			w.Write([]byte("data: [DONE]\n\n"))
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

func testController(t *testing.T, base string) (*controller, *panel, *fakeHost, *ui.Tester) {
	p, h, tt := testPanel(t, map[string]string{
		"service": "openAI", "service.openAI.baseURL": base, "service.openAI.apiKey": "x",
	})
	c := newController(p.s, p)
	c.cursor = func() mygo.Point { return mygo.Point{} }
	return c, p, h, tt
}

func TestControllerStreamsATranslation(t *testing.T) {
	srv := mockService(t)
	c, p, h, tt := testController(t, srv.URL+"/v1")
	c.translate("Hello world, how are you?", "", nil)
	h.drain(t, tt, func() bool { return !p.streaming })
	tt.Frame()
	if p.result != "你好" || !strings.Contains(p.status, "gpt-4o-mini") || p.target != lang.ChineseSimplified {
		t.Errorf("result %q, status %q, target %s", p.result, p.status, p.target)
	}
	if !tt.HasText("English → 简体中文") {
		t.Errorf("texts %q", tt.Texts())
	}
}

func TestControllerShowsErrorsWithTheirButton(t *testing.T) {
	srv := mockService(t)
	c, p, h, tt := testController(t, srv.URL+"/fail")
	opened := 0
	c.openSettings = func() { opened++ }
	c.translate("Hello", "", nil)
	h.drain(t, tt, func() bool { return p.notice != nil })
	if !strings.Contains(p.notice.message, "Incorrect API key") || p.notice.action.label != "Open Settings…" {
		t.Fatalf("notice %+v", p.notice)
	}
	p.notice.action.run()
	if opened != 1 {
		t.Error("Open Settings")
	}
}

func TestControllerCallsAnEmptyReplyAnError(t *testing.T) {
	srv := mockService(t)
	c, p, h, tt := testController(t, srv.URL+"/empty")
	c.translate("Hello", "", nil)
	h.drain(t, tt, func() bool { return p.notice != nil })
	if p.notice.message != "OpenAI Compatible sent back an empty translation." || p.notice.action.label != "Retry" {
		t.Errorf("notice %+v", p.notice)
	}
}

func TestPickingATargetTranslatesAgain(t *testing.T) {
	srv := mockService(t)
	c, p, h, tt := testController(t, srv.URL+"/v1")
	c.translate("Hello", "", nil)
	h.drain(t, tt, func() bool { return !p.streaming })
	p.pickTarget(lang.Japanese)
	if c.target != lang.Japanese || !p.streaming {
		t.Errorf("target %s, streaming %v", c.target, p.streaming)
	}
	h.drain(t, tt, func() bool { return !p.streaming })
}

func TestTypedTextStaysInInputMode(t *testing.T) {
	srv := mockService(t)
	c, p, h, tt := testController(t, srv.URL+"/v1")
	c.showInput()
	tt.Frame()
	tt.Type("Good morning")
	tt.Key(0, ui.KeyEnter)
	h.drain(t, tt, func() bool { return p.result != "" && !p.streaming })
	if p.mode != modeInput || !p.sourceGrey || p.source != "Good morning" {
		t.Errorf("mode %v, grey %v, source %q", p.mode, p.sourceGrey, p.source)
	}
}

// TestShots draws the panel's states into TROT_SHOTS, for looking at
// them: TROT_SHOTS=build/shots go test -run TestShots ./cmd/trot
func TestShots(t *testing.T) {
	dir := os.Getenv("TROT_SHOTS")
	if dir == "" {
		t.Skip("TROT_SHOTS is not set")
	}
	os.MkdirAll(dir, 0o755)
	for _, dark := range []bool{false, true} {
		for name, setUp := range map[string]func(p *panel){
			"result": func(p *panel) {
				p.begin("The quick brown fox jumps over the lazy dog.", lang.English, lang.ChineseSimplified, service.OpenAI, mygo.Point{})
				p.append("敏捷的棕色狐狸跳过了那只懒狗。")
				p.finish("1.2 s · gpt-4o-mini")
			},
			"streaming": func(p *panel) {
				p.begin("The quick brown fox jumps over the lazy dog.", lang.English, lang.ChineseSimplified, service.OpenAI, mygo.Point{})
				p.append("敏捷的棕色")
			},
			"error": func(p *panel) {
				p.begin("Hello", lang.English, lang.ChineseSimplified, service.OpenAI, mygo.Point{})
				p.showError("The API key was rejected (HTTP 401).", &action{"Open Settings…", func() {}})
			},
			"input": func(p *panel) { p.showInput(mygo.Point{}, "", nil) },
			"paragraphs": func(p *panel) {
				p.begin("Two paragraphs.", lang.English, lang.ChineseSimplified, service.OpenAI, mygo.Point{})
				p.append("第一段文字，用来检查段落之间的距离。\n\n第二段文字，紧接着一个空行。\n第二段的第二行。")
				p.finish("0.9 s · gpt-4o-mini")
			},
			"reading": func(p *panel) { p.beginReading("Reading the selection…", mygo.Point{}, false) },
			"pinned": func(p *panel) {
				p.begin("The quick brown fox jumps over the lazy dog.", lang.English, lang.ChineseSimplified, service.OpenAI, mygo.Point{})
				p.append("敏捷的棕色狐狸跳过了那只懒狗。")
				p.finish("1.2 s · gpt-4o-mini")
				p.pinned = true
				p.copiedAt = time.Now()
			},
			"arabic": func(p *panel) {
				p.begin("Hello, how are you?", lang.English, lang.Arabic, service.Claude, mygo.Point{})
				p.append("مرحبا، كيف حالك؟")
				p.finish("0.8 s · claude-opus-5-5")
			},
		} {
			p, h, tt := testPanel(t, nil)
			tt.SetDark(dark)
			// Settled, without entrances half done.
			tt.SetPreferences(ui.Preferences{ReduceMotion: true})
			setUp(p)
			tt.Frame()
			tt.Frame()
			tt.SetSize(panelWidth, h.height)
			tt.SetScale(2)
			tt.Frame()
			suffix := "light"
			if dark {
				suffix = "dark"
			}
			f, err := os.Create(filepath.Join(dir, name+"-"+suffix+".png"))
			if err != nil {
				t.Fatal(err)
			}
			png.Encode(f, tt.Image())
			f.Close()
		}
	}
}

// TestPlaceholderUntilFirstWord: a line of placeholder holds the place of
// the translation until its first word, at the height of that word's
// line, so the card doesn't move as it lands.
func TestPlaceholderUntilFirstWord(t *testing.T) {
	p, h, tt := testPanel(t, nil)
	p.begin("Hello", lang.English, lang.ChineseSimplified, service.OpenAI, mygo.Point{})
	tt.Frame()
	tt.Frame()
	if _, ok := tt.Find("Translating"); !ok {
		t.Fatalf("no placeholder in %q", tt.Texts())
	}
	waiting := h.height
	p.append("你好")
	tt.Frame()
	tt.Frame()
	if _, ok := tt.Find("Translating"); ok {
		t.Error("the placeholder stayed after the first word")
	}
	if h.height != waiting {
		t.Errorf("the card went from %d to %d as the first word landed", waiting, h.height)
	}
}
