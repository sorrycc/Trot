// Package selection reads the text selected in the frontmost app.
//
// Accessibility answers directly in native apps. Where it can't say, a
// synthesized ⌘C goes through the pasteboard, and the pasteboard is put
// back afterwards. Before that, the app's Edit > Copy item is checked: when
// it's disabled there is no selection, and nothing is copied.
package selection

import (
	"strings"
	"sync"
	"time"

	"trot/internal/mac"
)

// System is what the reader asks of macOS.
type System interface {
	Frontmost() (pid int, bundle string)
	SelectedText() (mac.AXAnswer, string)
	EnableManualAccessibility(pid int)
	CopyMenuEnabled(pid int) (enabled, ok bool)
	ChangeCount() int
	TakeSnapshot() (mac.Snapshot, bool)
	Restore(mac.Snapshot)
	PostCopy()
	PasteboardString() string
	CopiedFromEmptySelection() bool
}

// macSystem is the real macOS.
type macSystem struct{}

func (macSystem) Frontmost() (int, string)             { return mac.Frontmost() }
func (macSystem) SelectedText() (mac.AXAnswer, string) { return mac.SelectedText() }
func (macSystem) EnableManualAccessibility(pid int)    { mac.EnableManualAccessibility(pid) }
func (macSystem) CopyMenuEnabled(pid int) (bool, bool) { return mac.CopyMenuEnabled(pid) }
func (macSystem) ChangeCount() int                     { return mac.ChangeCount() }
func (macSystem) TakeSnapshot() (mac.Snapshot, bool)   { return mac.TakeSnapshot() }
func (macSystem) Restore(s mac.Snapshot)               { mac.Restore(s) }
func (macSystem) PostCopy()                            { mac.PostCopy() }
func (macSystem) PasteboardString() string             { return mac.PasteboardString() }
func (macSystem) CopiedFromEmptySelection() bool       { return mac.CopiedFromEmptySelection() }

// lineCopyingEditors copy the whole line when nothing is selected. A ⌘C
// there would send a line the user never picked.
var lineCopyingEditors = map[string]bool{
	"com.microsoft.VSCode": true, "com.microsoft.VSCodeInsiders": true, "com.todesktop.230313mzl4w4u92": true,
	"dev.zed.Zed": true, "com.sublimetext.4": true, "com.sublimetext.3": true, "com.github.atom": true,
}

// marksEmptySelection are the editors that say in their pasteboard data
// when a copy came from an empty selection: VS Code and Cursor.
func marksEmptySelection(bundle string) bool {
	return strings.HasPrefix(bundle, "com.microsoft.VSCode") || bundle == "com.todesktop.230313mzl4w4u92"
}

// Reader reads selections, one at a time.
type Reader struct {
	sys System
	// Poll is how often and how many times the pasteboard is checked for
	// the copy: apps take a few ms, slow ones a few hundred.
	Poll      time.Duration
	PollTimes int

	mu sync.Mutex
	// inFlight is the read under way: a second ⌘C while the first is in
	// flight would snapshot the first copy as the clipboard to restore.
	inFlight chan struct{}
	result   string
	// lateCopy stops the watch for a copy that lands after a read gave up.
	lateCopy chan struct{}
}

// New returns a reader of the real system.
func New() *Reader { return NewWith(macSystem{}) }

// NewWith returns a reader of sys, for tests.
func NewWith(sys System) *Reader {
	return &Reader{sys: sys, Poll: 16 * time.Millisecond, PollTimes: 25}
}

// Read returns the selected text, "" when there is none. It blocks for up
// to about half a second: call it off the main thread.
func (r *Reader) Read() string {
	r.mu.Lock()
	if ch := r.inFlight; ch != nil {
		r.mu.Unlock()
		<-ch
		r.mu.Lock()
		defer r.mu.Unlock()
		return r.result
	}
	// A new read takes its own snapshot; the old watcher has nothing left
	// to protect.
	if r.lateCopy != nil {
		close(r.lateCopy)
		r.lateCopy = nil
	}
	ch := make(chan struct{})
	r.inFlight = ch
	r.mu.Unlock()

	text := r.readOnce()

	r.mu.Lock()
	r.result = text
	r.inFlight = nil
	r.mu.Unlock()
	close(ch)
	return text
}

func (r *Reader) readOnce() string {
	pid, bundle := r.sys.Frontmost()
	lineCopying := lineCopyingEditors[bundle]
	answer, text := r.sys.SelectedText()
	if answer == mac.AXUnavailable && lineCopying && pid != 0 {
		// Electron builds its accessibility tree only when asked to.
		r.sys.EnableManualAccessibility(pid)
		answer, text = r.sys.SelectedText()
	}
	switch answer {
	case mac.AXText:
		return text
	case mac.AXEmpty:
		if lineCopying {
			return ""
		}
	case mac.AXUnavailable:
		// Without a marker for an empty selection, a copy here could be a
		// whole line; only VS Code and Cursor set one.
		if lineCopying && !marksEmptySelection(bundle) {
			return ""
		}
	}
	// The menu check and the pasteboard snapshot are both slow calls into
	// other processes, so they run side by side.
	type snap struct {
		s  mac.Snapshot
		ok bool
	}
	saved := make(chan snap, 1)
	go func() {
		s, ok := r.sys.TakeSnapshot()
		saved <- snap{s, ok}
	}()
	if pid != 0 {
		if enabled, ok := r.sys.CopyMenuEnabled(pid); ok && !enabled {
			return ""
		}
	}
	sn := <-saved
	return r.readThroughPasteboard(pid, sn.s, sn.ok)
}

// readThroughPasteboard copies with ⌘C and reads the copy. saved is the
// pasteboard as it was, to put back after; without it the copy stays,
// which beats a half-restored clipboard.
func (r *Reader) readThroughPasteboard(pid int, saved mac.Snapshot, haveSaved bool) string {
	before := r.sys.ChangeCount()
	r.sys.PostCopy()
	for range r.PollTimes {
		time.Sleep(r.Poll)
		if r.sys.ChangeCount() != before {
			break
		}
	}
	if r.sys.ChangeCount() == before {
		// A copy landing after this point would replace the clipboard for
		// good, so keep watching a moment and put it back then.
		if haveSaved {
			stop := make(chan struct{})
			r.mu.Lock()
			r.lateCopy = stop
			r.mu.Unlock()
			go r.restoreLateCopy(saved, before, pid, stop)
		}
		return ""
	}
	ours := r.sys.ChangeCount()
	text := r.sys.PasteboardString()
	empty := r.sys.CopiedFromEmptySelection()
	// Only undo the copy itself, never something written since.
	if haveSaved && r.sys.ChangeCount() == ours {
		r.sys.Restore(saved)
	}
	if empty {
		return ""
	}
	return text
}

func (r *Reader) restoreLateCopy(saved mac.Snapshot, before, pid int, stop chan struct{}) {
	defer func() {
		r.mu.Lock()
		if r.lateCopy == stop {
			r.lateCopy = nil
		}
		r.mu.Unlock()
	}()
	for range 16 {
		select {
		case <-stop:
			return
		case <-time.After(50 * time.Millisecond):
		}
		if n := r.sys.ChangeCount(); n != before {
			// Only the copy we asked for, from the app we asked.
			if front, _ := r.sys.Frontmost(); n == before+1 && front == pid {
				r.sys.Restore(saved)
			}
			return
		}
	}
}
