package main

import (
	"strings"
	"time"

	"github.com/egoist/mygo/ui"

	"trot/internal/shortcut"
)

// keyNames are the keys a shortcut can use, as accelerators name them, by
// their place on a US keyboard, which is how hotkeys are registered.
var keyNames = map[ui.Key]string{
	ui.KeyA: "a", ui.KeyB: "b", ui.KeyC: "c", ui.KeyD: "d", ui.KeyE: "e", ui.KeyF: "f", ui.KeyG: "g",
	ui.KeyH: "h", ui.KeyI: "i", ui.KeyJ: "j", ui.KeyK: "k", ui.KeyL: "l", ui.KeyM: "m", ui.KeyN: "n",
	ui.KeyO: "o", ui.KeyP: "p", ui.KeyQ: "q", ui.KeyR: "r", ui.KeyS: "s", ui.KeyT: "t", ui.KeyU: "u",
	ui.KeyV: "v", ui.KeyW: "w", ui.KeyX: "x", ui.KeyY: "y", ui.KeyZ: "z",
	ui.Key0: "0", ui.Key1: "1", ui.Key2: "2", ui.Key3: "3", ui.Key4: "4", ui.Key5: "5", ui.Key6: "6",
	ui.Key7: "7", ui.Key8: "8", ui.Key9: "9",
	ui.KeyMinus: "-", ui.KeyEqual: "=", ui.KeyComma: ",", ui.KeyPeriod: ".", ui.KeySlash: "/",
	ui.KeySemicolon: ";", ui.KeyQuote: "'", ui.KeyBracketLeft: "[", ui.KeyBracketRight: "]",
	ui.KeyBackslash: "\\", ui.KeyBackquote: "`",
	ui.KeySpace: "Space", ui.KeyEnter: "Enter", ui.KeyTab: "Tab", ui.KeyBackspace: "Backspace",
	ui.KeyDelete: "Delete", ui.KeyHome: "Home", ui.KeyEnd: "End", ui.KeyPageUp: "PageUp",
	ui.KeyPageDown: "PageDown", ui.KeyLeft: "Left", ui.KeyRight: "Right", ui.KeyUp: "Up", ui.KeyDown: "Down",
	ui.KeyF1: "F1", ui.KeyF2: "F2", ui.KeyF3: "F3", ui.KeyF4: "F4", ui.KeyF5: "F5", ui.KeyF6: "F6",
	ui.KeyF7: "F7", ui.KeyF8: "F8", ui.KeyF9: "F9", ui.KeyF10: "F10", ui.KeyF11: "F11", ui.KeyF12: "F12",
}

// keysOf is a shortcut's keys, one for each modifier and one for the key:
// ⌥D is ⌥ and D.
func keysOf(s shortcut.Shortcut) []string {
	mods := []rune(s.Modifiers())
	keys := make([]string, 0, len(mods)+1)
	for _, m := range mods {
		keys = append(keys, string(m))
	}
	if key := strings.TrimPrefix(s.Display(), s.Modifiers()); key != "" {
		keys = append(keys, key)
	}
	return keys
}

// shortcutOf is the combination a key press types, by the key's place.
func shortcutOf(mods ui.Modifiers, key ui.Key) (shortcut.Shortcut, bool) {
	name, ok := keyNames[key]
	if !ok {
		return shortcut.Shortcut{}, false
	}
	return shortcut.Shortcut{
		Ctrl: mods&ui.Ctrl != 0, Alt: mods&ui.Alt != 0, Shift: mods&ui.Shift != 0, Cmd: mods&ui.Super != 0,
		Key: name,
	}, true
}

// recorder is the state of a button that records a shortcut: click it,
// then press the combination. While recording it shows the modifiers held
// so far. Escape cancels and Delete clears.
type recorder struct {
	recording bool
}

// recorderButton builds the button for current (ok false for none), and
// calls record with the combination pressed, or nil for Delete.
// onRecording hears when recording starts and ends, as global hotkeys
// would take the keys meanwhile.
func recorderButton(c *ui.Context, r *recorder, label string, current shortcut.Shortcut, ok bool,
	record func(*shortcut.Shortcut), onRecording func(bool)) ui.Element {
	t := c.Theme()
	b := ui.ButtonBase(c).MinWidth(156).Height(24).Padding(0, 10).Center().Radius(6).Focusable()
	set := func(on bool) {
		if r.recording != on {
			r.recording = on
			onRecording(on)
		}
	}
	// Recording ends as the keyboard goes elsewhere.
	if r.recording && !b.Focused() {
		set(false)
	}
	b.HandleInput(func(ev ui.InputEvent) bool {
		if !r.recording || ev.Kind != ui.InputKeyDown {
			return false
		}
		mods := ev.Mods & (ui.Ctrl | ui.Alt | ui.Shift | ui.Super)
		if mods == 0 && ev.Key == ui.KeyEscape {
			set(false)
			return true
		}
		if mods == 0 && (ev.Key == ui.KeyBackspace || ev.Key == ui.KeyDelete) {
			set(false)
			record(nil)
			return true
		}
		if sc, ok := shortcutOf(mods, ev.PhysicalKey); ok && sc.Usable() {
			set(false)
			record(&sc)
		}
		return true
	})
	if b.Clicked() {
		set(!r.recording)
		if r.recording {
			b.Focus()
		}
	}
	var text string
	var caps []string
	color, fill, border := t.Text, t.Surface, t.Border
	if b.Hovered() {
		fill = t.SurfaceHover
	}
	switch {
	case r.recording:
		// A soft wash of the accent, under an edge that breathes while it
		// waits for the keys.
		fill, border = t.Accent.Alpha(0.12), t.Accent
		color = t.Accent
		held := c.Modifiers()
		mods := shortcut.Shortcut{Ctrl: held&ui.Ctrl != 0, Alt: held&ui.Alt != 0,
			Shift: held&ui.Shift != 0, Cmd: held&ui.Super != 0}.Modifiers()
		text = "Type Shortcut…"
		if mods != "" {
			text = mods + "…"
		}
		b.Label("Recording a shortcut for " + label)
	case ok:
		text = current.Display()
		caps = keysOf(current)
		b.Label(label + " shortcut " + text)
	default:
		text = "None"
		color = t.TextMuted
		b.Label("No shortcut for " + label)
	}
	// The button turns to the accent as it starts listening, and back.
	border = b.AnimateColor("border", border, hoverAnim)
	if r.recording && !c.Preferences().ReduceMotion {
		border = border.Alpha(0.45 + 0.55*pulse(c, 1200*time.Millisecond))
	}
	b.Background(b.AnimateColor("fill", fill, hoverAnim)).Border(1, border)
	pressScale(b, b.Pressed())
	b.Children(func() {
		// A shortcut shows as its keys, as the panel's hints do.
		if caps != nil {
			ui.Row(c.Key("caps")).Gap(3).AlignItems(ui.Center).Children(func() {
				for i, k := range caps {
					keycapIn(c.Key(i), k, t.Text)
				}
			})
			return
		}
		label := ui.Text(c.Key("text"), text).FontSize(13).SingleLine().ContentTransition(swap)
		label.TextColor(label.AnimateColor("color", color, hoverAnim))
	})
	return b
}
