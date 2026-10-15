package main

import (
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"trot/internal/mac"
)

const (
	// mouseGap is how far the panel sits from the mouse.
	mouseGap = 12
	// screenMargin keeps the panel off the edges of the work area.
	screenMargin = 8
	// growDuration is how long the card takes to grow to new text: short
	// enough that a stream of chunks reads as one motion, long enough to
	// see.
	growDuration = 0.14
	fadeIn       = 0.16
	fadeOut      = 0.12
)

// panelWindow is the floating panel's window: over every app, on every
// Space, taking the keyboard without activating Trot, so the app the user
// was in keeps its menu bar.
type panelWindow struct {
	win *mygo.Window
	p   *panel
	// preview shows the panel without taking the keyboard, and clicks
	// elsewhere leave it open, for looking at it from a script.
	preview bool

	// anchor is the point a panel being presented goes near, once its
	// height is known.
	anchor   mygo.Point
	placing  bool
	fading   bool
	height   int
	area     mygo.Rectangle
	stop     func() // the click monitor
	shownGen int
	// quitting lets the window close, which quitting closes every window
	// to do.
	quitting bool
}

func newPanelWindow(p *panel, preview bool) *panelWindow {
	w := &panelWindow{p: p, preview: preview, height: 160}
	w.win = mygo.NewWindow(mygo.WindowOptions{
		Title:         "Translation",
		Panel:         true,
		Hidden:        true,
		Frameless:     true,
		Transparent:   true,
		Vibrancy:      mygo.VibrancyPopover,
		Width:         panelWidth,
		Height:        w.height,
		DisableResize: true,
		Content:       ui.View(p.view),
	})
	mac.RoundCorners(w.win.NativeHandle(), panelRadius)
	// Escape and ⌘W the view leaves close the panel: hide it rather than
	// close it, so it shows again at once.
	w.win.OnClose(func(e *mygo.CloseEvent) {
		if w.quitting {
			return
		}
		e.PreventDefault()
		p.close()
	})
	mygo.App.OnBeforeQuit(func(*mygo.QuitEvent) { w.quitting = true })
	p.host = w
	return w
}

func (w *panelWindow) visible() bool { return w.win.IsVisible() && !w.fading }
func (w *panelWindow) key() bool     { return w.win.IsVisible() && w.win.IsFocused() }

func (w *panelWindow) room() int {
	if w.area.Height > 0 {
		return w.area.Height
	}
	return mygo.Screen.DisplayNearestPoint(mygo.Screen.CursorScreenPoint()).WorkArea.Height
}

func (w *panelWindow) reduceMotion() bool { return mygo.Theme.Preferences().ReduceMotion }

func (w *panelWindow) update(fn func()) { w.win.Update(fn) }

// popup shows a menu once the frame that asked for it is done: a menu runs
// a loop of its own, which inside a frame never draws it.
func (w *panelWindow) popup(m *mygo.Menu, x, y int, done func()) {
	go mygo.RunOnMain(func() {
		m.PopupAt(w.win, x, y)
		done()
		w.win.Invalidate()
	})
}

func (w *panelWindow) present(point mygo.Point, key bool) {
	key = key && !w.preview
	if w.win.IsVisible() {
		if w.fading {
			// Shown again during the fade-out: keep it, at full strength.
			w.fading = false
			w.shownGen++
			mac.AnimateAlpha(w.win.NativeHandle(), 1, w.duration(fadeIn))
			w.watchClicks()
		}
		if key && !w.win.IsFocused() {
			w.win.Show()
		}
		w.win.Invalidate()
		return
	}
	w.anchor = point
	w.area = mygo.Screen.DisplayNearestPoint(point).WorkArea
	w.placing = true
	// The next frame reports the card's height even when it is the last
	// presentation's, which places the panel.
	w.p.fitted = 0
	w.fading = false
	w.shownGen++
	// Out of sight until the first frame tells the card's height.
	mac.AnimateAlpha(w.win.NativeHandle(), 0, 0)
	if key {
		w.win.Show()
	} else {
		w.win.ShowInactive()
	}
	w.watchClicks()
	w.win.Invalidate()
}

func (w *panelWindow) duration(d float64) float64 {
	if w.reduceMotion() {
		return 0
	}
	return d
}

// fit sizes the window to the card. The first height of a presentation
// places the panel and fades it in; later ones grow it with the top edge
// still, so text streaming in pushes the bottom down smoothly.
func (w *panelWindow) fit(height int) {
	w.height = height
	h := w.win.NativeHandle()
	if w.placing {
		w.placing = false
		x, y := place(w.anchor, panelWidth, height, w.area)
		mac.AnimateFrame(h, float64(x), float64(y), panelWidth, float64(height), 0)
		mac.AnimateAlpha(h, 1, w.duration(fadeIn))
		mac.InvalidateShadow(h)
		return
	}
	b := w.win.Bounds()
	y := b.Y
	if w.area.Height > 0 && y+height > w.area.Y+w.area.Height-screenMargin {
		y = max(w.area.Y+screenMargin, w.area.Y+w.area.Height-screenMargin-height)
	}
	d := w.duration(growDuration)
	mac.AnimateFrame(h, float64(b.X), float64(y), panelWidth, float64(height), d)
	// The window's shadow is cast for the old shape; once the card has
	// grown into the new one, it is cast again to match.
	gen := w.shownGen
	time.AfterFunc(time.Duration((d+0.02)*float64(time.Second)), func() {
		mygo.RunOnMain(func() {
			if gen == w.shownGen && w.win.IsVisible() {
				mac.InvalidateShadow(h)
			}
		})
	})
}

func (w *panelWindow) dismiss() {
	if !w.win.IsVisible() || w.fading {
		return
	}
	w.fading = true
	w.shownGen++
	gen := w.shownGen
	w.unwatchClicks()
	d := w.duration(fadeOut)
	mac.AnimateAlpha(w.win.NativeHandle(), 0, d)
	time.AfterFunc(time.Duration(d*float64(time.Second)), func() {
		mygo.RunOnMain(func() {
			if gen == w.shownGen && w.fading {
				w.fading = false
				w.win.Hide()
			}
		})
	})
}

// watchClicks closes the panel on clicks in other apps, unless it's
// pinned. Clicks in Trot's own windows never reach the monitor.
func (w *panelWindow) watchClicks() {
	if w.stop != nil || w.preview {
		return
	}
	w.stop = mac.MonitorClicks(func() { w.update(w.p.outsideClick) })
}

func (w *panelWindow) unwatchClicks() {
	if w.stop != nil {
		w.stop()
		w.stop = nil
	}
}

// place puts a panel of width and height below and to the right of the
// point, or above it when the work area ends too soon, and in any case
// within the work area.
func place(point mygo.Point, width, height int, area mygo.Rectangle) (x, y int) {
	x = point.X + mouseGap
	y = point.Y + mouseGap
	bottom := area.Y + area.Height - screenMargin
	if y+height > bottom && point.Y-mouseGap-height >= area.Y+screenMargin {
		y = point.Y - mouseGap - height
	}
	x = min(max(x, area.X+screenMargin), area.X+area.Width-width-screenMargin)
	y = min(max(y, area.Y+screenMargin), bottom-height)
	return x, y
}
