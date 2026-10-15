// Package settings keeps every setting the Settings window shows in a JSON
// file. API keys are there too: the keychain would ask for permission after
// every rebuild, since an ad-hoc signed app has a new identity each time.
//
// The keys are those Trot before 0.5 kept in its user defaults, such as
// "firstLanguage" and "service.openAI.apiKey", so a launch argument names a
// setting as it always did.
package settings

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"trot/internal/lang"
	"trot/internal/service"
	"trot/internal/shortcut"
)

// Settings are the saved settings, and the launch arguments that override
// them for one run.
type Settings struct {
	mu        sync.Mutex
	path      string
	values    map[string]string
	overrides map[string]string
	listeners []func(key string)
}

// Load reads the settings at path; a missing or unreadable file is empty
// settings. overrides are read in place of the saved values without being
// saved, as launch arguments are.
func Load(path string, overrides map[string]string) *Settings {
	s := &Settings{path: path, values: map[string]string{}, overrides: overrides}
	if data, err := os.ReadFile(path); err == nil {
		var v map[string]any
		if json.Unmarshal(data, &v) == nil {
			for k, val := range v {
				switch val := val.(type) {
				case string:
					s.values[k] = val
				case bool:
					if val {
						s.values[k] = "1"
					}
				}
			}
		}
	}
	return s
}

// Path is the file the settings are saved in.
func (s *Settings) Path() string { return s.path }

// Exists reports whether the file has been written, which the first
// launch hasn't.
func (s *Settings) Exists() bool {
	_, err := os.Stat(s.path)
	return err == nil
}

// OnChange calls fn with the key of each setting that changes.
func (s *Settings) OnChange(fn func(key string)) {
	s.mu.Lock()
	s.listeners = append(s.listeners, fn)
	s.mu.Unlock()
}

// Get returns a setting and whether it is set, an override first.
func (s *Settings) Get(key string) (string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if v, ok := s.overrides[key]; ok {
		return v, true
	}
	v, ok := s.values[key]
	return v, ok
}

func (s *Settings) get(key string) string {
	v, _ := s.Get(key)
	return v
}

// Set saves a setting; "" removes it unless keepEmpty.
func (s *Settings) set(key, value string, keepEmpty bool) {
	s.mu.Lock()
	old, had := s.values[key]
	if value == "" && !keepEmpty {
		delete(s.values, key)
	} else {
		s.values[key] = value
	}
	_, has := s.values[key]
	changed := old != value || had != has
	listeners := append([]func(string){}, s.listeners...)
	if changed {
		s.saveLocked()
	}
	s.mu.Unlock()
	if changed {
		for _, fn := range listeners {
			fn(key)
		}
	}
}

func (s *Settings) remove(key string) {
	s.mu.Lock()
	_, had := s.values[key]
	delete(s.values, key)
	listeners := append([]func(string){}, s.listeners...)
	if had {
		s.saveLocked()
	}
	s.mu.Unlock()
	if had {
		for _, fn := range listeners {
			fn(key)
		}
	}
}

// saveLocked writes the file, through a temporary one so a crash never
// leaves half of it.
func (s *Settings) saveLocked() {
	if s.path == "" {
		return
	}
	data, err := json.MarshalIndent(s.values, "", "  ")
	if err != nil {
		return
	}
	os.MkdirAll(filepath.Dir(s.path), 0o755)
	tmp := s.path + ".tmp"
	if os.WriteFile(tmp, append(data, '\n'), 0o600) == nil {
		os.Rename(tmp, s.path)
	}
}

// Flag reports a boolean setting.
func (s *Settings) Flag(key string) bool { return parseBool(s.get(key)) }

// SetFlag saves a boolean setting.
func (s *Settings) SetFlag(key string, on bool) {
	if on {
		s.set(key, "1", false)
	} else {
		s.remove(key)
	}
}

func parseBool(v string) bool {
	switch strings.ToLower(v) {
	case "1", "yes", "true":
		return true
	}
	return false
}

// FirstLanguage is the language most text gets translated into.
func (s *Settings) FirstLanguage() lang.Language {
	if l, ok := lang.Parse(s.get("firstLanguage")); ok {
		return l
	}
	return lang.ChineseSimplified
}

// SecondLanguage is where text already in the first language goes.
func (s *Settings) SecondLanguage() lang.Language {
	if l, ok := lang.Parse(s.get("secondLanguage")); ok {
		return l
	}
	return lang.English
}

// SetLanguages sets both languages. Picking one that the other already is
// swaps them, so the rule always has two places to go.
func (s *Settings) SetLanguages(first, second lang.Language) {
	first, second = lang.Resolve(first, second, s.FirstLanguage(), s.SecondLanguage())
	s.set("firstLanguage", string(first), false)
	s.set("secondLanguage", string(second), false)
}

// Target is where text in detected goes.
func (s *Settings) Target(detected lang.Language) lang.Language {
	return lang.Target(detected, s.FirstLanguage(), s.SecondLanguage())
}

// PreferredChinese is the Chinese the user reads.
func (s *Settings) PreferredChinese() lang.Language {
	return lang.PreferredChinese(s.FirstLanguage(), s.SecondLanguage())
}

// Service is the active service.
func (s *Settings) Service() service.Kind {
	if k, ok := service.ParseKind(s.get("service")); ok {
		return k
	}
	return service.OpenAI
}

// SetService makes k the active service.
func (s *Settings) SetService(k service.Kind) { s.set("service", string(k), false) }

func serviceKey(k service.Kind, field string) string { return "service." + string(k) + "." + field }

// BaseURL is the base URL as typed; "" means the service's default.
func (s *Settings) BaseURL(k service.Kind) string { return s.get(serviceKey(k, "baseURL")) }

// SetBaseURL saves the base URL, trimmed.
func (s *Settings) SetBaseURL(k service.Kind, v string) {
	s.set(serviceKey(k, "baseURL"), strings.TrimSpace(v), false)
}

// Model is the model as typed; "" means the service's default.
func (s *Settings) Model(k service.Kind) string { return s.get(serviceKey(k, "model")) }

// SetModel saves the model, trimmed.
func (s *Settings) SetModel(k service.Kind, v string) {
	s.set(serviceKey(k, "model"), strings.TrimSpace(v), false)
}

// APIKey is the service's API key.
func (s *Settings) APIKey(k service.Kind) string { return s.get(serviceKey(k, "apiKey")) }

// SetAPIKey saves the API key, trimmed.
func (s *Settings) SetAPIKey(k service.Kind, v string) {
	s.set(serviceKey(k, "apiKey"), strings.TrimSpace(v), false)
}

// ActiveModel is the model in use: the one set, else the default.
func (s *Settings) ActiveModel(k service.Kind) string {
	if m := s.Model(k); m != "" {
		return m
	}
	return k.DefaultModel()
}

// ActiveBaseURL is the base URL in use: the one set, tidied, else the
// default.
func (s *Settings) ActiveBaseURL(k service.Kind) string {
	if b := s.BaseURL(k); b != "" {
		return service.NormalizeBaseURL(b, k)
	}
	return k.DefaultBaseURL()
}

// Config is the service's settings, as a request takes them.
func (s *Settings) Config(k service.Kind) service.Config {
	return service.Config{BaseURL: s.ActiveBaseURL(k), APIKey: s.APIKey(k), Model: s.ActiveModel(k)}
}

// NeedsSetup reports whether the active service still lacks the key it
// needs, so a translation can't work until Settings has been visited.
func (s *Settings) NeedsSetup() bool {
	k := s.Service()
	return k.NeedsKey() && s.APIKey(k) == ""
}

func shortcutKey(a shortcut.Action) string { return "shortcut." + string(a) }

// Shortcut is the action's shortcut; ok is false for none. Unset means
// the default.
func (s *Settings) Shortcut(a shortcut.Action) (sc shortcut.Shortcut, ok bool) {
	v, set := s.Get(shortcutKey(a))
	if !set {
		return a.Default(), true
	}
	if sc, ok = shortcut.Parse(v); ok {
		return sc, true
	}
	return shortcut.ParseLegacy(v)
}

// SetShortcut saves the action's shortcut, nil for none.
func (s *Settings) SetShortcut(a shortcut.Action, sc *shortcut.Shortcut) {
	v := ""
	if sc != nil {
		v = sc.Accelerator()
	}
	s.set(shortcutKey(a), v, true)
}

// ResetShortcut goes back to the action's default.
func (s *Settings) ResetShortcut(a shortcut.Action) { s.remove(shortcutKey(a)) }

// ShortcutIsCustom reports whether the user changed or cleared the
// shortcut, so Reset has work to do.
func (s *Settings) ShortcutIsCustom(a shortcut.Action) bool {
	_, set := s.Get(shortcutKey(a))
	return set
}
