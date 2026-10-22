// Package cloudsync syncs Trot's settings with the person's Mon account, as
// one settings document of Mon's:
//
//	{"settings": {"firstLanguage": "zh-Hans", "shortcut.translateInput": "Alt+A", …}}
//
// The settings merge key by key against the snapshot of the last sync, the
// base: a key changed on one side only takes that side's value, and one
// changed on both this Mac's. It is Mayoi's cloudsync, for settings that
// are all strings and without a keybindings.json.
package cloudsync

import (
	"context"
	"encoding/json"
	"errors"
	"maps"
	"os"
	"path/filepath"
	"sync"
	"time"

	"trot/internal/mon"
)

// App is Trot's client id with Mon, and its settings document's name.
const App = "trot"

// Snapshot is what syncs: the settings by their keys in settings.json.
type Snapshot map[string]string

// document is the shape of the account's settings document.
type document struct {
	Settings Snapshot `json:"settings"`
}

// Merge merges what changed here since base, local, with what changed in
// the account, remote. Where both changed a setting, local's stays.
func Merge(base, local, remote Snapshot) Snapshot {
	merged := Snapshot{}
	keys := map[string]bool{}
	for _, m := range []Snapshot{base, local, remote} {
		for k := range m {
			keys[k] = true
		}
	}
	for k := range keys {
		side := remote
		if changed(base, local, k) {
			side = local
		}
		if v, ok := side[k]; ok {
			merged[k] = v
		}
	}
	return merged
}

// changed reports whether the key of to differs from that of from, as
// being set in one only.
func changed(from, to Snapshot, k string) bool {
	a, aok := from[k]
	b, bok := to[k]
	return aok != bok || a != b
}

// Local is this Mac's settings. The methods are called on the engine's
// goroutine.
type Local interface {
	// Read returns the settings as they are now.
	Read() (Snapshot, error)
	// Apply makes s the settings. Where they are no longer read, as Read
	// returned them, it changes nothing and fails with ErrStale.
	Apply(read, s Snapshot) error
	// IsDefault reports whether s is what a first launch has, which a
	// first sync replaces without asking.
	IsDefault(s Snapshot) bool
	// Known reports whether this version of Trot has the setting key: one
	// it does not have, of a newer Trot's, it keeps as the account has it.
	Known(key string) bool
}

// State is what the engine keeps between launches, in sync.json: the
// account, and the version of the account's document and the snapshot of
// the last sync. Base is nil until the first sync.
type State struct {
	UserID  string    `json:"userId"`
	Name    string    `json:"name,omitempty"`
	Email   string    `json:"email,omitempty"`
	Version int64     `json:"version"`
	Base    *Snapshot `json:"base,omitempty"`
	// SyncedAt is when this Mac and the account last agreed.
	SyncedAt time.Time `json:"syncedAt,omitzero"`
}

// Choice is how a first sync goes, where both this Mac and the account
// have settings of their own.
type Choice int

const (
	// Ask fails a first sync with ErrNeedsChoice when both sides have
	// settings of their own.
	Ask Choice = iota
	// UseAccount replaces this Mac's with the account's.
	UseAccount
	// UseLocal replaces the account's with this Mac's.
	UseLocal
)

// ErrNeedsChoice is what a first sync fails with when this Mac and the
// account both have settings of their own: sync again with UseAccount or
// UseLocal.
var ErrNeedsChoice = errors.New("cloudsync: this Mac and the account both have settings")

// ErrStale is what Apply fails with when this Mac's settings changed since
// they were read, as the person changed one as a sync ran. A sync reads
// them again and merges anew, staleTries times at most, and fails with it
// then: the change syncs as it is pushed.
var ErrStale = errors.New("cloudsync: this Mac's settings changed as they synced")

const staleTries = 3

// Result says what a sync did.
type Result struct {
	// Applied is set when the account's changes applied here, Pushed when
	// this Mac's were saved to the account.
	Applied, Pushed bool
}

// Engine syncs Local with the account. Its methods may be called from any
// goroutine; one sync runs at a time.
type Engine struct {
	Client *mon.Client
	Local  Local
	path   string

	mu    sync.Mutex // held through a sync
	smu   sync.Mutex // guards state
	state State
}

// New returns an engine whose state is kept at path, as it last was.
func New(client *mon.Client, local Local, path string) *Engine {
	e := &Engine{Client: client, Local: local, path: path}
	if data, err := os.ReadFile(path); err == nil {
		json.Unmarshal(data, &e.state)
	}
	return e
}

// State returns the engine's state.
func (e *Engine) State() State {
	e.smu.Lock()
	defer e.smu.Unlock()
	return e.state
}

// SignedIn starts syncing for the person u, whose token the client has,
// with a first sync to come.
func (e *Engine) SignedIn(u *mon.User) error {
	return e.setState(State{UserID: u.ID, Name: u.Name, Email: u.Email})
}

// Refreshed takes the person's name and email as the account has them
// now, keeping the rest.
func (e *Engine) Refreshed(u *mon.User) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	st := e.State()
	if st.UserID != u.ID || st.Name == u.Name && st.Email == u.Email {
		return nil
	}
	st.Name, st.Email = u.Name, u.Email
	return e.setState(st)
}

// Forget forgets the account and the last sync, as the person signs out.
func (e *Engine) Forget() {
	e.smu.Lock()
	e.state = State{}
	e.smu.Unlock()
	os.Remove(e.path)
}

func (e *Engine) setState(st State) error {
	e.smu.Lock()
	e.state = st
	e.smu.Unlock()
	data, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	os.MkdirAll(filepath.Dir(e.path), 0o755)
	tmp := e.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, e.path)
}

// Push saves this Mac's changes to the account, unless there are none
// since the last sync: then it does not ask the account at all.
func (e *Engine) Push(ctx context.Context) (Result, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	st := e.State()
	if st.Base == nil {
		return Result{}, nil
	}
	local, err := e.Local.Read()
	if err != nil {
		return Result{}, err
	}
	if maps.Equal(e.withUnknown(*st.Base, local), *st.Base) {
		return Result{}, nil
	}
	return e.sync(ctx, Ask)
}

// Sync fetches the account's settings, merges them with this Mac's and
// saves the merge on both sides. A first sync goes as choice says.
// mon.ErrUnauthorized means the person signed out elsewhere, as from the
// account page: the engine has forgotten the account.
func (e *Engine) Sync(ctx context.Context, choice Choice) (Result, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.sync(ctx, choice)
}

func (e *Engine) sync(ctx context.Context, choice Choice) (Result, error) {
	st := e.State()
	if st.UserID == "" {
		return Result{}, mon.ErrUnauthorized
	}
	remote, version, err := e.fetch(ctx)
	if err != nil {
		return Result{}, err
	}
	local, err := e.Local.Read()
	if err != nil {
		return Result{}, err
	}
	var base Snapshot
	if st.Base != nil {
		base = *st.Base
	} else {
		// The first sync: the side that has nothing of its own takes the
		// other's, else the one chosen wins.
		switch {
		case version == 0 || choice == UseLocal:
			base = remote
		case e.Local.IsDefault(local) || choice == UseAccount:
			base = local
		default:
			return Result{}, ErrNeedsChoice
		}
	}
	// This Mac's changes are those of local since base, which merge with
	// each version of the account's this sync gets.
	mine := e.withUnknown(base, local)
	var res Result
	var applied Snapshot
	stale := 0
	for {
		merged := Merge(base, mine, remote)
		now := mine
		if applied != nil {
			now = applied
		}
		if !maps.Equal(merged, now) {
			err := e.Local.Apply(local, maps.Clone(merged))
			if errors.Is(err, ErrStale) && stale < staleTries {
				// The person changed a setting since it was read: merge
				// that change too, rather than undo it.
				stale++
				fresh, err := e.Local.Read()
				if err != nil {
					return res, err
				}
				mine, local = since(mine, local, fresh), fresh
				continue
			}
			if err != nil {
				return res, err
			}
			res.Applied = true
			applied = merged
			// As applied, which a later Apply of this sync checks against.
			if local, err = e.Local.Read(); err != nil {
				return res, err
			}
		}
		if maps.Equal(merged, remote) && version > 0 {
			st.Version, st.Base, st.SyncedAt = version, &merged, time.Now()
			return res, e.setState(st)
		}
		saved, err := e.Client.PutSettings(ctx, App, version, document{merged})
		var conflictErr *mon.ConflictError
		if errors.As(err, &conflictErr) {
			// Another Mac saved since: merge this Mac's changes again, with
			// what it saved.
			if remote, err = decode(conflictErr.Current.Data); err != nil {
				return res, err
			}
			version = conflictErr.Current.Version
			continue
		}
		if err != nil {
			return res, e.signedOut(err)
		}
		res.Pushed = true
		st.Version, st.Base, st.SyncedAt = saved.Version, &merged, time.Now()
		return res, e.setState(st)
	}
}

// since returns mine with what changed from was to now, read as a sync
// ran: the person's changes of then, over this Mac's of before.
func since(mine, was, now Snapshot) Snapshot {
	out := maps.Clone(mine)
	if out == nil {
		out = Snapshot{}
	}
	for _, m := range []Snapshot{was, now} {
		for k := range m {
			if !changed(was, now, k) {
				continue
			}
			if v, ok := now[k]; ok {
				out[k] = v
			} else {
				delete(out, k)
			}
		}
	}
	return out
}

// withUnknown returns local with the settings of base this version of
// Trot does not know, as unchanged, rather than as removed.
func (e *Engine) withUnknown(base, local Snapshot) Snapshot {
	out := maps.Clone(local)
	if out == nil {
		out = Snapshot{}
	}
	for k, v := range base {
		if _, ok := out[k]; !ok && !e.Local.Known(k) {
			out[k] = v
		}
	}
	return out
}

// fetch returns the account's settings and their version, 0 for none.
func (e *Engine) fetch(ctx context.Context) (Snapshot, int64, error) {
	st, err := e.Client.GetSettings(ctx, App)
	if err != nil {
		return nil, 0, e.signedOut(err)
	}
	s, err := decode(st.Data)
	return s, st.Version, err
}

func decode(data json.RawMessage) (Snapshot, error) {
	var d document
	if len(data) == 0 || string(data) == "null" {
		return Snapshot{}, nil
	}
	if err := json.Unmarshal(data, &d); err != nil {
		return nil, err
	}
	if d.Settings == nil {
		d.Settings = Snapshot{}
	}
	return d.Settings, nil
}

// signedOut forgets the account when err says its token is no more.
func (e *Engine) signedOut(err error) error {
	if errors.Is(err, mon.ErrUnauthorized) {
		e.Forget()
	}
	return err
}
