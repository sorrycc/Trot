//go:build darwin

package mac

import (
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/egoist/mygo/ui"
)

func TestDominantLanguage(t *testing.T) {
	langs := []string{"en", "fr", "de", "es"}
	cases := map[string]string{
		"The quick brown fox jumps over the lazy dog.":          "en",
		"Le renard brun rapide saute par-dessus le chien.":      "fr",
		"Der schnelle braune Fuchs springt über den Hund.":      "de",
		"El rápido zorro marrón salta sobre el perro perezoso.": "es",
	}
	for text, want := range cases {
		if got := DominantLanguage(text, langs); got != want {
			t.Errorf("DominantLanguage(%q) = %q, want %q", text, got, want)
		}
	}
}

func TestLanguageHypotheses(t *testing.T) {
	h := LanguageHypotheses("这个国家", []string{"zh-Hans", "zh-Hant"}, 2)
	if h["zh-Hans"] < 0.9 {
		t.Errorf("hypotheses %v, want zh-Hans sure", h)
	}
}

func TestRecognizeText(t *testing.T) {
	img := ui.Render(func(c *ui.Context) {
		c.Root().Background(ui.RGB(255, 255, 255))
		ui.Column(c).Fill().Padding(20).Children(func() {
			ui.Text(c, "Hello from Trot").FontSize(32).TextColor(ui.RGB(0, 0, 0))
		})
	}, 480, 120, 2)
	path := filepath.Join(t.TempDir(), "shot.png")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := png.Encode(f, img); err != nil {
		t.Fatal(err)
	}
	f.Close()
	lines, err := RecognizeText(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(lines, " "); !strings.Contains(got, "Hello from Trot") {
		t.Errorf("recognized %q", got)
	}
}

func TestPasteboardRoundTrip(t *testing.T) {
	if testing.Short() {
		t.Skip("touches the clipboard")
	}
	saved, ok := TakeSnapshot()
	if !ok {
		t.Skip("clipboard too large to snapshot")
	}
	defer Restore(saved)
	Restore(Snapshot{{{Type: "public.utf8-plain-text", Data: []byte("  trot test  ")}}})
	if got := PasteboardString(); got != "trot test" {
		t.Errorf("PasteboardString = %q", got)
	}
	before := ChangeCount()
	Restore(Snapshot{{{Type: "public.utf8-plain-text", Data: []byte("again")}}})
	if ChangeCount() == before {
		t.Error("change count did not move")
	}
}

func TestBindings(t *testing.T) {
	_ = IsTrusted()
	_ = ScreenCaptureAllowed()
	pid, _ := Frontmost()
	if pid < 0 {
		t.Errorf("pid %d", pid)
	}
	SelectedText()
	s := NewSynthesizer()
	if s.Speaking() {
		t.Error("speaking before speaking")
	}
}
