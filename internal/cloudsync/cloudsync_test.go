package cloudsync

import (
	"context"
	"encoding/json"
	"errors"
	"maps"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"trot/internal/mon"
)

// account is a Mon that keeps one settings document.
type account struct {
	mu      sync.Mutex
	version int64
	data    json.RawMessage
	revoked bool
}

func (a *account) serve(t *testing.T) *httptest.Server {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a.mu.Lock()
		defer a.mu.Unlock()
		if a.revoked {
			w.WriteHeader(401)
			return
		}
		if r.URL.Path != "/api/v1/settings/"+App {
			w.WriteHeader(404)
			return
		}
		current := func() mon.Settings { return mon.Settings{App: App, Version: a.version, Data: a.data} }
		switch r.Method {
		case "GET":
			json.NewEncoder(w).Encode(current())
		case "PUT":
			var body struct {
				BaseVersion int64           `json:"base_version"`
				Data        json.RawMessage `json:"data"`
			}
			json.NewDecoder(r.Body).Decode(&body)
			if body.BaseVersion != a.version {
				w.WriteHeader(409)
				json.NewEncoder(w).Encode(map[string]any{"error": "version_conflict", "current": current()})
				return
			}
			a.version++
			a.data = body.Data
			json.NewEncoder(w).Encode(current())
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

func (a *account) settings() Snapshot {
	a.mu.Lock()
	defer a.mu.Unlock()
	s, _ := decode(a.data)
	return s
}

// mac is a Mac's settings.
type mac struct {
	s Snapshot
	// edit, when set, changes a setting as the next Apply comes, as the
	// person would.
	edit func(Snapshot)
}

func (m *mac) Read() (Snapshot, error) { return maps.Clone(m.s), nil }

func (m *mac) Apply(read, s Snapshot) error {
	if m.edit != nil {
		m.edit(m.s)
		m.edit = nil
	}
	if !maps.Equal(read, m.s) {
		return ErrStale
	}
	m.s = s
	return nil
}

func (m *mac) IsDefault(s Snapshot) bool { return len(s) == 0 }

func (m *mac) Known(key string) bool { return !strings.HasPrefix(key, "future") }

func signedIn(t *testing.T, srv *httptest.Server, m *mac) *Engine {
	c := mon.New(srv.URL)
	c.Token = "mon_x"
	e := New(c, m, filepath.Join(t.TempDir(), "sync.json"))
	if err := e.SignedIn(&mon.User{ID: "u1", Name: "Ada"}); err != nil {
		t.Fatal(err)
	}
	return e
}

func TestMerge(t *testing.T) {
	base := Snapshot{"a": "1", "b": "1", "c": "1"}
	local := Snapshot{"a": "2", "b": "1"}
	remote := Snapshot{"a": "3", "b": "3", "c": "1", "d": "3"}
	got := Merge(base, local, remote)
	want := Snapshot{"a": "2", "b": "3", "d": "3"}
	if !maps.Equal(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestFirstSyncs(t *testing.T) {
	ctx := context.Background()
	acc := &account{}
	srv := acc.serve(t)

	// An empty account takes this Mac's.
	a := &mac{s: Snapshot{"firstLanguage": "ja"}}
	e := signedIn(t, srv, a)
	if res, err := e.Sync(ctx, Ask); err != nil || !res.Pushed || acc.settings()["firstLanguage"] != "ja" {
		t.Fatalf("%v %v %v", res, err, acc.settings())
	}

	// A fresh Mac takes the account's.
	b := &mac{s: Snapshot{}}
	if res, err := signedIn(t, srv, b).Sync(ctx, Ask); err != nil || !res.Applied || b.s["firstLanguage"] != "ja" {
		t.Fatalf("%v %v %v", res, err, b.s)
	}

	// A Mac with settings of its own asks, then goes as chosen.
	c := &mac{s: Snapshot{"firstLanguage": "de"}}
	ec := signedIn(t, srv, c)
	if _, err := ec.Sync(ctx, Ask); !errors.Is(err, ErrNeedsChoice) {
		t.Fatalf("asks: %v", err)
	}
	if _, err := ec.Sync(ctx, UseAccount); err != nil || c.s["firstLanguage"] != "ja" {
		t.Fatalf("use account: %v %v", err, c.s)
	}
	d := &mac{s: Snapshot{"firstLanguage": "fr"}}
	if _, err := signedIn(t, srv, d).Sync(ctx, UseLocal); err != nil || acc.settings()["firstLanguage"] != "fr" {
		t.Fatalf("use local: %v %v", err, acc.settings())
	}
}

func TestTwoMacsMerge(t *testing.T) {
	ctx := context.Background()
	acc := &account{}
	srv := acc.serve(t)
	a := &mac{s: Snapshot{"firstLanguage": "ja", "service": "mon"}}
	ea := signedIn(t, srv, a)
	ea.Sync(ctx, Ask)
	b := &mac{s: Snapshot{}}
	eb := signedIn(t, srv, b)
	eb.Sync(ctx, Ask)

	// Each changes a setting of its own; both end with both.
	a.s["service"] = "deepL"
	b.s["secondLanguage"] = "fr"
	if res, err := ea.Push(ctx); err != nil || !res.Pushed {
		t.Fatalf("push a: %v %v", res, err)
	}
	if res, err := eb.Push(ctx); err != nil || !res.Pushed || !res.Applied || b.s["service"] != "deepL" {
		t.Fatalf("push b: %v %v %v", res, err, b.s)
	}
	if _, err := ea.Sync(ctx, Ask); err != nil || a.s["secondLanguage"] != "fr" {
		t.Fatalf("pull a: %v %v", err, a.s)
	}
	// Nothing changed: a push doesn't ask the account.
	acc.revoked = true
	if res, err := ea.Push(ctx); err != nil || res.Pushed {
		t.Errorf("idle push: %v %v", res, err)
	}
}

func TestStaleApplyKeepsTheChange(t *testing.T) {
	ctx := context.Background()
	acc := &account{}
	srv := acc.serve(t)
	a := &mac{s: Snapshot{"firstLanguage": "ja"}}
	signedIn(t, srv, a).Sync(ctx, Ask)
	b := &mac{s: Snapshot{}}
	eb := signedIn(t, srv, b)
	b.edit = func(s Snapshot) { s["secondLanguage"] = "ko" }
	if _, err := eb.Sync(ctx, Ask); err != nil {
		t.Fatal(err)
	}
	if b.s["firstLanguage"] != "ja" || b.s["secondLanguage"] != "ko" || acc.settings()["secondLanguage"] != "ko" {
		t.Errorf("mac %v, account %v", b.s, acc.settings())
	}
}

func TestUnknownSettingsStay(t *testing.T) {
	ctx := context.Background()
	acc := &account{}
	srv := acc.serve(t)
	newer := &mac{s: Snapshot{"future.thing": "x", "firstLanguage": "ja"}}
	signedIn(t, srv, newer).Sync(ctx, Ask)
	older := &mac{s: Snapshot{}}
	eo := signedIn(t, srv, older)
	eo.Sync(ctx, Ask)
	// The older Trot drops what it doesn't know as it saves its settings.
	delete(older.s, "future.thing")
	older.s["firstLanguage"] = "de"
	if _, err := eo.Push(ctx); err != nil {
		t.Fatal(err)
	}
	if got := acc.settings(); got["future.thing"] != "x" || got["firstLanguage"] != "de" {
		t.Errorf("account %v", got)
	}
}

func TestRevokedTokenForgets(t *testing.T) {
	acc := &account{revoked: true}
	srv := acc.serve(t)
	e := signedIn(t, srv, &mac{s: Snapshot{}})
	if _, err := e.Sync(context.Background(), Ask); !errors.Is(err, mon.ErrUnauthorized) || e.State().UserID != "" {
		t.Errorf("%v %+v", err, e.State())
	}
}
