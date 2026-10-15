// Package shortcut holds the key combinations of Trot's global hotkeys, as
// MyGo's accelerators, which go by the key's place on a US keyboard.
package shortcut

import (
	"strconv"
	"strings"
)

// Shortcut is a key combination, such as Option+D.
type Shortcut struct {
	Ctrl, Alt, Shift, Cmd bool
	// Key is the key as accelerators name it: a lowercase letter, a digit,
	// a sign, or a name such as "Space", "Up" or "F5".
	Key string
}

// Accelerator is the shortcut as MyGo's accelerators and settings write it:
// "Alt+Shift+D".
func (s Shortcut) Accelerator() string {
	var parts []string
	if s.Ctrl {
		parts = append(parts, "Ctrl")
	}
	if s.Alt {
		parts = append(parts, "Alt")
	}
	if s.Shift {
		parts = append(parts, "Shift")
	}
	if s.Cmd {
		parts = append(parts, "Cmd")
	}
	key := s.Key
	switch {
	case key == "+":
		key = "Plus"
	case len(key) == 1:
		key = strings.ToUpper(key)
	}
	return strings.Join(append(parts, key), "+")
}

// Parse reads an accelerator as Accelerator writes it.
func Parse(text string) (Shortcut, bool) {
	var s Shortcut
	parts := strings.Split(text, "+")
	// "Cmd++" ends in an empty part for the plus key.
	if strings.HasSuffix(text, "++") {
		parts = append(parts[:len(parts)-2], "+")
	}
	if len(parts) == 0 {
		return s, false
	}
	for _, p := range parts[:len(parts)-1] {
		switch strings.ToLower(p) {
		case "ctrl", "control":
			s.Ctrl = true
		case "alt", "option":
			s.Alt = true
		case "shift":
			s.Shift = true
		case "cmd", "command", "super", "cmdorctrl", "commandorcontrol":
			s.Cmd = true
		default:
			return Shortcut{}, false
		}
	}
	key := parts[len(parts)-1]
	switch {
	case strings.EqualFold(key, "plus"):
		key = "+"
	case len([]rune(key)) == 1:
		key = strings.ToLower(key)
	default:
		name, ok := canonicalName(key)
		if !ok {
			return Shortcut{}, false
		}
		key = name
	}
	if key == "" {
		return Shortcut{}, false
	}
	s.Key = key
	return s, true
}

var names = []string{"Space", "Enter", "Tab", "Backspace", "Delete", "Escape", "Home", "End",
	"PageUp", "PageDown", "Insert", "Left", "Right", "Up", "Down"}

func canonicalName(key string) (string, bool) {
	for _, n := range names {
		if strings.EqualFold(n, key) {
			return n, true
		}
	}
	if n, ok := functionNumber(key); ok {
		return "F" + strconv.Itoa(n), true
	}
	return "", false
}

func functionNumber(key string) (int, bool) {
	if len(key) < 2 || (key[0] != 'F' && key[0] != 'f') {
		return 0, false
	}
	n, err := strconv.Atoi(key[1:])
	if err != nil || n < 1 || n > 20 || strconv.Itoa(n) != key[1:] {
		return 0, false
	}
	return n, true
}

// IsFunctionKey reports F1 to F20.
func (s Shortcut) IsFunctionKey() bool {
	_, ok := functionNumber(s.Key)
	return ok && s.Key[0] == 'F'
}

// Usable reports whether it can be a global hotkey: a function key needs
// no modifier; anything else needs Control, Option or Command, or the
// hotkey would swallow ordinary typing in every app.
func (s Shortcut) Usable() bool {
	return s.Key != "" && (s.Ctrl || s.Alt || s.Cmd || s.IsFunctionKey())
}

// Modifiers are the modifier symbols, as menus show them: ⌃⌥⇧⌘.
func (s Shortcut) Modifiers() string {
	var b strings.Builder
	for _, m := range []struct {
		on  bool
		sym string
	}{{s.Ctrl, "⌃"}, {s.Alt, "⌥"}, {s.Shift, "⇧"}, {s.Cmd, "⌘"}} {
		if m.on {
			b.WriteString(m.sym)
		}
	}
	return b.String()
}

// Display is the shortcut as menus show it: ⌥D.
func (s Shortcut) Display() string {
	return s.Modifiers() + keyName(s.Key)
}

func keyName(key string) string {
	switch key {
	case "Up":
		return "↑"
	case "Down":
		return "↓"
	case "Left":
		return "←"
	case "Right":
		return "→"
	case "Enter":
		return "↩"
	case "Tab":
		return "⇥"
	case "Backspace":
		return "⌫"
	case "Delete":
		return "⌦"
	case "Escape":
		return "⎋"
	}
	if len([]rune(key)) == 1 {
		return strings.ToUpper(key)
	}
	return key
}

// Action is what a global hotkey does.
type Action string

const (
	TranslateSelection  Action = "translateSelection"
	TranslateInput      Action = "translateInput"
	TranslateScreenshot Action = "translateScreenshot"
)

// Actions are the hotkey actions, in the order menus list them.
var Actions = []Action{TranslateSelection, TranslateInput, TranslateScreenshot}

// DisplayName is the action as menus name it.
func (a Action) DisplayName() string {
	switch a {
	case TranslateSelection:
		return "Translate Selection"
	case TranslateInput:
		return "Translate Input…"
	case TranslateScreenshot:
		return "Translate Screenshot…"
	}
	return string(a)
}

// Default is the action's shortcut out of the box: Bob's, so the fingers
// already know them.
func (a Action) Default() Shortcut {
	switch a {
	case TranslateSelection:
		return Shortcut{Alt: true, Key: "d"}
	case TranslateInput:
		return Shortcut{Alt: true, Key: "a"}
	}
	return Shortcut{Alt: true, Key: "s"}
}

// ansiKeys are the keys at the macOS virtual key codes of a US keyboard,
// which the shortcuts of Trot before 0.5 were stored by.
var ansiKeys = map[int]string{
	0x00: "a", 0x01: "s", 0x02: "d", 0x03: "f", 0x04: "h", 0x05: "g", 0x06: "z", 0x07: "x",
	0x08: "c", 0x09: "v", 0x0B: "b", 0x0C: "q", 0x0D: "w", 0x0E: "e", 0x0F: "r", 0x10: "y",
	0x11: "t", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
	0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "o", 0x20: "u",
	0x21: "[", 0x22: "i", 0x23: "p", 0x25: "l", 0x26: "j", 0x27: "'", 0x28: "k", 0x29: ";",
	0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "n", 0x2E: "m", 0x2F: ".", 0x32: "`",
	0x24: "Enter", 0x30: "Tab", 0x31: "Space", 0x33: "Backspace", 0x35: "Escape",
	0x75: "Delete", 0x73: "Home", 0x77: "End", 0x74: "PageUp", 0x79: "PageDown", 0x72: "Insert",
	0x7B: "Left", 0x7C: "Right", 0x7D: "Down", 0x7E: "Up",
	0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
	0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14", 0x71: "F15",
	0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
}

// ParseLegacy reads a shortcut as Trot before 0.5 stored it, such as
// "shift+opt+d@2": modifiers, the character the key typed, and its key
// code, which is what counts.
func ParseLegacy(text string) (Shortcut, bool) {
	at := strings.LastIndex(text, "@")
	if at < 0 {
		return Shortcut{}, false
	}
	code, err := strconv.Atoi(text[at+1:])
	if err != nil {
		return Shortcut{}, false
	}
	key, ok := ansiKeys[code]
	if !ok {
		return Shortcut{}, false
	}
	s := Shortcut{Key: key}
	rest := text[:at]
	for {
		p, r, found := strings.Cut(rest, "+")
		if !found || r == "" {
			break
		}
		switch p {
		case "ctrl":
			s.Ctrl = true
		case "opt":
			s.Alt = true
		case "shift":
			s.Shift = true
		case "cmd":
			s.Cmd = true
		default:
			return Shortcut{}, false
		}
		rest = r
	}
	if len([]rune(rest)) != 1 {
		return Shortcut{}, false
	}
	return s, true
}
