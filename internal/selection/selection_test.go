package selection

import (
	"sync"
	"testing"
	"time"

	"trot/internal/mac"
)

// fake is a frontmost app and a pasteboard.
type fake struct {
	mu          sync.Mutex
	bundle      string
	answer      mac.AXAnswer
	axText      string
	manualAX    bool // answers only after EnableManualAccessibility
	copyEnabled bool
	menuKnown   bool
	selected    string // what ⌘C copies; "" copies nothing
	copyDelay   time.Duration
	emptyMarker bool

	clipboard string
	count     int
	copies    int
	restores  int
}

func (f *fake) Frontmost() (int, string) { return 42, f.bundle }
func (f *fake) SelectedText() (mac.AXAnswer, string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.manualAX {
		return mac.AXUnavailable, ""
	}
	return f.answer, f.axText
}
func (f *fake) EnableManualAccessibility(int) {
	f.mu.Lock()
	f.manualAX = false
	f.mu.Unlock()
}
func (f *fake) CopyMenuEnabled(int) (bool, bool) { return f.copyEnabled, f.menuKnown }
func (f *fake) ChangeCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.count
}
func (f *fake) TakeSnapshot() (mac.Snapshot, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return mac.Snapshot{{{Type: "public.utf8-plain-text", Data: []byte(f.clipboard)}}}, true
}
func (f *fake) Restore(s mac.Snapshot) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.clipboard = string(s[0][0].Data)
	f.count++
	f.restores++
}
func (f *fake) PostCopy() {
	f.mu.Lock()
	f.copies++
	sel, delay := f.selected, f.copyDelay
	f.mu.Unlock()
	if sel == "" {
		return
	}
	write := func() {
		f.mu.Lock()
		f.clipboard = sel
		f.count++
		f.mu.Unlock()
	}
	if delay > 0 {
		time.AfterFunc(delay, write)
	} else {
		write()
	}
}
func (f *fake) PasteboardString() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.clipboard
}
func (f *fake) CopiedFromEmptySelection() bool { return f.emptyMarker }

func reader(f *fake) *Reader {
	r := NewWith(f)
	r.Poll, r.PollTimes = time.Millisecond, 5
	return r
}

func TestAccessibilityAnswersFirst(t *testing.T) {
	f := &fake{answer: mac.AXText, axText: "hello"}
	if got := reader(f).Read(); got != "hello" || f.copies != 0 {
		t.Errorf("got %q, %d copies", got, f.copies)
	}
}

func TestCopyFallbackRestoresTheClipboard(t *testing.T) {
	f := &fake{bundle: "com.google.Chrome", answer: mac.AXUnavailable, copyEnabled: true, menuKnown: true,
		selected: "from the web", clipboard: "mine"}
	if got := reader(f).Read(); got != "from the web" {
		t.Errorf("got %q", got)
	}
	if f.clipboard != "mine" {
		t.Errorf("clipboard %q", f.clipboard)
	}
}

func TestDisabledCopyMeansNoSelection(t *testing.T) {
	f := &fake{answer: mac.AXUnavailable, copyEnabled: false, menuKnown: true, selected: "x"}
	if got := reader(f).Read(); got != "" || f.copies != 0 {
		t.Errorf("got %q, %d copies", got, f.copies)
	}
}

func TestLineCopyingEditorsAreNeverSentCopyWithoutASelection(t *testing.T) {
	f := &fake{bundle: "dev.zed.Zed", answer: mac.AXEmpty, copyEnabled: true, menuKnown: true, selected: "a whole line"}
	if got := reader(f).Read(); got != "" || f.copies != 0 {
		t.Errorf("empty: got %q, %d copies", got, f.copies)
	}
	f = &fake{bundle: "dev.zed.Zed", answer: mac.AXUnavailable, copyEnabled: true, menuKnown: true, selected: "a whole line"}
	if got := reader(f).Read(); got != "" || f.copies != 0 {
		t.Errorf("unavailable: got %q, %d copies", got, f.copies)
	}
}

func TestVSCodeEmptySelectionMarkerIsHonoured(t *testing.T) {
	f := &fake{bundle: "com.microsoft.VSCode", answer: mac.AXUnavailable, copyEnabled: true, menuKnown: true,
		selected: "the current line", emptyMarker: true, clipboard: "mine"}
	if got := reader(f).Read(); got != "" || f.clipboard != "mine" {
		t.Errorf("got %q, clipboard %q", got, f.clipboard)
	}
}

func TestElectronIsAskedForItsTree(t *testing.T) {
	f := &fake{bundle: "com.microsoft.VSCode", answer: mac.AXText, axText: "code", manualAX: true}
	if got := reader(f).Read(); got != "code" || f.copies != 0 {
		t.Errorf("got %q, %d copies", got, f.copies)
	}
}

func TestALateCopyIsPutBack(t *testing.T) {
	f := &fake{answer: mac.AXUnavailable, menuKnown: false, selected: "slow", copyDelay: 60 * time.Millisecond, clipboard: "mine"}
	if got := reader(f).Read(); got != "" {
		t.Errorf("got %q", got)
	}
	time.Sleep(200 * time.Millisecond)
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.clipboard != "mine" || f.restores != 1 {
		t.Errorf("clipboard %q after %d restores", f.clipboard, f.restores)
	}
}

func TestConcurrentReadsShareOne(t *testing.T) {
	f := &fake{answer: mac.AXUnavailable, copyEnabled: true, menuKnown: true, selected: "once", copyDelay: 2 * time.Millisecond}
	r := reader(f)
	var wg sync.WaitGroup
	results := make([]string, 3)
	for i := range results {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results[i] = r.Read()
		}()
	}
	wg.Wait()
	for _, got := range results {
		if got != "once" {
			t.Errorf("results %q", results)
		}
	}
}
