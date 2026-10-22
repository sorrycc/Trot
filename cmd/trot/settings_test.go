package main

import (
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"trot/internal/settings"
	"trot/internal/shortcut"
)

// TestSettingsTabsFade: picking a pane fades the fill of the tab that was
// picked before, rather than dropping it at once.
func TestSettingsTabsFade(t *testing.T) {
	if testing.Short() {
		t.Skip("waits for the animation")
	}
	a := &trotApp{s: settings.Load(filepath.Join(t.TempDir(), "settings.json"), nil)}
	v := newSettingsView(a)
	v.showPane("About")
	tt := ui.NewTester(v.view, settingsWidth, 500)
	tt.Frame()
	time.Sleep(300 * time.Millisecond)
	tt.Frame()
	about, ok := tt.Find("About")
	if !ok {
		t.Fatalf("no About tab in %q", tt.Texts())
	}
	// A point of the About tab's fill, inside its edge.
	x, y := int(about.X)+6, int(about.Y+about.H/2)
	picked := tt.Image().RGBAAt(x, y)
	clickAt := time.Now()
	if err := tt.Click("Shortcuts"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	fading := tt.Image().RGBAAt(x, y)
	// A busy machine can take the whole fade to click and draw.
	caught := time.Since(clickAt) < tabAnim.Duration/2
	time.Sleep(400 * time.Millisecond)
	tt.Frame()
	clear := tt.Image().RGBAAt(x, y)
	if v.pane != 2 || !tt.HasText("Translate Selection") {
		t.Fatalf("pane %d, texts %q", v.pane, tt.Texts())
	}
	if picked.R >= clear.R || caught && !(picked.R < fading.R && fading.R < clear.R) {
		t.Errorf("the About tab's fill went %v, %v, %v; want it to fade", picked, fading, clear)
	}
}

// TestSettingsShots draws each pane of Settings into TROT_SHOTS, light and
// dark: TROT_SHOTS=build/shots go test -run TestSettingsShots ./cmd/trot
func TestSettingsShots(t *testing.T) {
	dir := os.Getenv("TROT_SHOTS")
	if dir == "" {
		t.Skip("TROT_SHOTS is not set")
	}
	os.MkdirAll(dir, 0o755)
	for _, dark := range []bool{false, true} {
		for _, name := range panes {
			// OpenAI Compatible has no account to sign in to.
			a := &trotApp{s: settings.Load(filepath.Join(t.TempDir(), "settings.json"), map[string]string{"service": "openAI"})}
			a.account = &account{a: a}
			v := newSettingsView(a)
			// The system's state as granted, without asking macOS.
			v.system, v.checkedAt = systemState{trusted: true}, time.Now().Add(time.Hour)
			v.resize = func(int) {}
			v.showPane(name)
			tt := ui.NewTester(v.view, settingsWidth, 800)
			tt.SetDark(dark)
			tt.SetPreferences(ui.Preferences{ReduceMotion: true})
			tt.Frame()
			tt.Frame()
			tt.SetSize(settingsWidth, v.fitted)
			tt.SetScale(2)
			tt.Frame()
			suffix := "light"
			if dark {
				suffix = "dark"
			}
			f, err := os.Create(filepath.Join(dir, "settings-"+strings.ToLower(name)+"-"+suffix+".png"))
			if err != nil {
				t.Fatal(err)
			}
			png.Encode(f, tt.Image())
			f.Close()
		}
	}
}

// TestKeysOf: a shortcut shows as one keycap per modifier and one for
// its key.
func TestKeysOf(t *testing.T) {
	got := strings.Join(keysOf(shortcut.Shortcut{Ctrl: true, Cmd: true, Key: "Space"}), " ")
	if got != "⌃ ⌘ Space" {
		t.Errorf("keys %q", got)
	}
}
