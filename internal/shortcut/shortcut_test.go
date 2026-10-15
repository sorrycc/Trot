package shortcut

import "testing"

func TestAcceleratorRoundTrips(t *testing.T) {
	for _, s := range []Shortcut{
		{Alt: true, Shift: true, Key: "d"},
		{Ctrl: true, Cmd: true, Key: "a"},
		{Cmd: true, Key: "+"},
		{Alt: true, Key: "Space"},
		{Key: "F5"},
		{Cmd: true, Key: "/"},
	} {
		got, ok := Parse(s.Accelerator())
		if !ok || got != s {
			t.Errorf("Parse(%q) = %+v %v, want %+v", s.Accelerator(), got, ok, s)
		}
	}
	if got := (Shortcut{Alt: true, Shift: true, Key: "d"}).Accelerator(); got != "Alt+Shift+D" {
		t.Error(got)
	}
}

func TestParseRejectsMalformed(t *testing.T) {
	for _, text := range []string{"", "Alt+", "Hyper+D", "Alt+Banana", "F0", "F25"} {
		if _, ok := Parse(text); ok {
			t.Errorf("parsed %q", text)
		}
	}
}

func TestDisplay(t *testing.T) {
	cases := map[string]Shortcut{
		"⌃⌥⇧⌘D":  {Ctrl: true, Alt: true, Shift: true, Cmd: true, Key: "d"},
		"⌥Space": {Alt: true, Key: "Space"},
		"F5":     {Key: "F5"},
		"⌘↑":     {Cmd: true, Key: "Up"},
	}
	for want, s := range cases {
		if got := s.Display(); got != want {
			t.Errorf("got %q, want %q", got, want)
		}
	}
}

func TestUsable(t *testing.T) {
	if (Shortcut{Key: "d"}).Usable() || (Shortcut{Shift: true, Key: "d"}).Usable() {
		t.Error("a bare letter is not usable")
	}
	if !(Shortcut{Alt: true, Key: "d"}).Usable() || !(Shortcut{Key: "F5"}).Usable() {
		t.Error("should be usable")
	}
}

func TestParseLegacy(t *testing.T) {
	cases := map[string]Shortcut{
		"opt+shift+d@2": {Alt: true, Shift: true, Key: "d"},
		"cmd+ctrl+a@0":  {Cmd: true, Ctrl: true, Key: "a"},
		"cmd+@@19":      {Cmd: true, Key: "2"},
		// The same physical key under another layout is the same hotkey.
		"opt+в@2": {Alt: true, Key: "d"},
		"@96":    {Key: "F5"},
	}
	for text, want := range cases {
		if got, ok := ParseLegacy(text); !ok || got != want {
			t.Errorf("ParseLegacy(%q) = %+v %v, want %+v", text, got, ok, want)
		}
	}
	for _, text := range []string{"", "opt+d", "opt+dd@2", "opt+d@x", "opt+d@999"} {
		if _, ok := ParseLegacy(text); ok {
			t.Errorf("parsed %q", text)
		}
	}
}

func TestDefaultsFollowBob(t *testing.T) {
	want := map[Action]string{TranslateSelection: "⌥D", TranslateInput: "⌥A", TranslateScreenshot: "⌥S"}
	for a, d := range want {
		if got := a.Default().Display(); got != d {
			t.Errorf("%s: %s", a, got)
		}
	}
}
