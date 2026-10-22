package main

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"trot/internal/settings"
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
