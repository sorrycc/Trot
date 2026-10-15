package settings

import (
	"os"
	"path/filepath"
	"testing"

	"trot/internal/lang"
	"trot/internal/service"
	"trot/internal/shortcut"
)

func temp(t *testing.T) *Settings {
	return Load(filepath.Join(t.TempDir(), "settings.json"), nil)
}

func TestDefaults(t *testing.T) {
	s := temp(t)
	if s.FirstLanguage() != lang.ChineseSimplified || s.SecondLanguage() != lang.English || s.Service() != service.OpenAI {
		t.Error("defaults")
	}
	if sc, ok := s.Shortcut(shortcut.TranslateSelection); !ok || sc.Display() != "⌥D" {
		t.Errorf("shortcut %v %v", sc, ok)
	}
	if s.Exists() {
		t.Error("nothing written yet")
	}
}

func TestSavesAndLoads(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	s := Load(path, nil)
	s.SetLanguages(lang.Japanese, lang.English)
	s.SetService(service.DeepL)
	s.SetAPIKey(service.DeepL, "  key:fx ")
	s.SetShortcut(shortcut.TranslateInput, nil)
	s.SetShortcut(shortcut.TranslateScreenshot, &shortcut.Shortcut{Cmd: true, Shift: true, Key: "2"})
	s.SetFlag("welcomed", true)

	r := Load(path, nil)
	if r.FirstLanguage() != lang.Japanese || r.Service() != service.DeepL || r.APIKey(service.DeepL) != "key:fx" || !r.Flag("welcomed") {
		t.Errorf("reloaded %v", r.values)
	}
	if _, ok := r.Shortcut(shortcut.TranslateInput); ok || !r.ShortcutIsCustom(shortcut.TranslateInput) {
		t.Error("a cleared shortcut stays cleared")
	}
	if sc, _ := r.Shortcut(shortcut.TranslateScreenshot); sc.Display() != "⇧⌘2" {
		t.Error(sc.Display())
	}
	r.ResetShortcut(shortcut.TranslateInput)
	if sc, ok := r.Shortcut(shortcut.TranslateInput); !ok || sc.Display() != "⌥A" || r.ShortcutIsCustom(shortcut.TranslateInput) {
		t.Error("reset")
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0o600 {
		t.Errorf("mode %v: the file holds API keys", info.Mode())
	}
}

func TestPickingTheOtherLanguageSwaps(t *testing.T) {
	s := temp(t)
	s.SetLanguages(lang.English, lang.English)
	if s.FirstLanguage() != lang.English || s.SecondLanguage() != lang.ChineseSimplified {
		t.Errorf("%s %s", s.FirstLanguage(), s.SecondLanguage())
	}
}

func TestTarget(t *testing.T) {
	s := temp(t)
	if s.Target(lang.English) != lang.ChineseSimplified || s.Target(lang.ChineseTraditional) != lang.English {
		t.Error("two-language rule")
	}
}

func TestNeedsSetup(t *testing.T) {
	s := temp(t)
	s.SetService(service.DeepL)
	if !s.NeedsSetup() {
		t.Error("no key")
	}
	s.SetAPIKey(service.DeepL, "key:fx")
	if s.NeedsSetup() {
		t.Error("key")
	}
	s.SetService(service.Google)
	if s.NeedsSetup() {
		t.Error("Google has no key to enter")
	}
}

func TestConfig(t *testing.T) {
	s := temp(t)
	if c := s.Config(service.OpenAI); c.BaseURL != "https://api.openai.com/v1" || c.Model != "gpt-4o-mini" {
		t.Errorf("%+v", c)
	}
	s.SetBaseURL(service.OpenAI, "localhost:11434/v1/chat/completions")
	if c := s.Config(service.OpenAI); c.BaseURL != "http://localhost:11434/v1" {
		t.Errorf("%+v", c)
	}
}

func TestOverridesWinWithoutBeingSaved(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	s := Load(path, map[string]string{"service": "google", "service.openAI.apiKey": "x"})
	if s.Service() != service.Google || s.APIKey(service.OpenAI) != "x" {
		t.Error("overrides")
	}
	s.SetService(service.Claude)
	if s.Service() != service.Google {
		t.Error("the override still wins")
	}
	if Load(path, nil).Service() != service.Claude {
		t.Error("the change is saved")
	}
}

func TestOnChange(t *testing.T) {
	s := temp(t)
	var keys []string
	s.OnChange(func(k string) { keys = append(keys, k) })
	s.SetService(service.Claude)
	s.SetService(service.Claude)
	if len(keys) != 1 || keys[0] != "service" {
		t.Errorf("%v", keys)
	}
}

func TestParsePlist(t *testing.T) {
	plist := `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSWindow Frame</key>
	<string>1 2 3 4</string>
	<key>firstLanguage</key>
	<string>ja</string>
	<key>nested</key>
	<dict><key>inner</key><string>no</string></dict>
	<key>blob</key>
	<data>AAAA</data>
	<key>shortcut.translateInput</key>
	<string>cmd+shift+a@0</string>
	<key>welcomed</key>
	<true/>
	<key>accessibilityPrompted</key>
	<false/>
	<key>count</key>
	<integer>3</integer>
</dict>
</plist>`
	got := parsePlist([]byte(plist))
	want := map[string]string{"NSWindow Frame": "1 2 3 4", "firstLanguage": "ja", "shortcut.translateInput": "cmd+shift+a@0", "welcomed": "1", "count": "3"}
	if len(got) != len(want) {
		t.Errorf("got %v", got)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %q, want %q", k, got[k], v)
		}
	}
}
