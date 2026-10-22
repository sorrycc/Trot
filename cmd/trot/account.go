package main

import (
	"cmp"
	"context"
	"errors"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/egoist/mygo"

	"trot/internal/cloudsync"
	"trot/internal/mon"
	"trot/internal/service"
	"trot/internal/settings"
)

const (
	// pushDelay is how long settings sync waits after a change before
	// saving it to the account, so that changes made together go together.
	pushDelay = 2 * time.Second
	// pullEvery is how often, at most, settings sync asks the account for
	// changes as Trot is used.
	pullEvery = 30 * time.Second
	// quitPush is how long, at most, quitting waits to save a change made
	// just before to the account.
	quitPush = 3 * time.Second
)

// syncRetryDelay is how long settings sync waits to try again after its
// n-th failure in a row, as the connection comes back.
func syncRetryDelay(n int) time.Duration {
	delays := []time.Duration{10 * time.Second, 30 * time.Second, time.Minute, 2 * time.Minute}
	if n < len(delays) {
		return delays[n]
	}
	return 5 * time.Minute
}

// account is the person's Mon account: the sign-in that the Mon service
// translates with, and settings sync. Its fields are the main thread's.
type account struct {
	a      *trotApp
	client *mon.Client
	engine *cloudsync.Engine

	// signin is the sign-in waiting for its approval, nil for none, and
	// signInErr says why the last one failed.
	signin    *signin
	signInErr string

	// asked is set once a first sync asked whose settings to keep, which a
	// sync of its own asks again only as the person syncs.
	asked    bool
	push     *time.Timer
	lastPull time.Time
	busy     int
	// failure says why the last sync failed, "" when it did not; retry
	// tries again at retryAt, after failures in a row.
	failure  string
	retry    *time.Timer
	retryAt  time.Time
	failures int
}

// signin is a sign-in waiting for the person to approve its code on Mon's
// website.
type signin struct {
	cancel context.CancelFunc
	// code and url are "" until Mon hands them out.
	code, url string
}

// startAccount takes the account signed in last, and syncs with it.
func (a *trotApp) startAccount() *account {
	c := &account{a: a, client: mon.New(service.MonURL())}
	c.client.Token = a.s.MonToken()
	path := ""
	if p := a.s.Path(); p != "" {
		path = filepath.Join(filepath.Dir(p), "sync.json")
	}
	c.engine = cloudsync.New(c.client, syncLocal{a.s}, path)
	a.s.OnChange(func(key string) {
		if settings.IsSynced(key) {
			mygo.RunOnMain(c.changed)
		}
	})
	mygo.App.OnWillQuit(func(*mygo.QuitEvent) { c.flush() })
	switch {
	case c.client.Token == "":
		// Signed out while Trot was away, as by editing settings.json.
		c.engine.Forget()
	case c.engine.State().UserID == "":
		// A token without its account, as sync.json was removed: ask Mon
		// whose it is.
		c.refreshProfile(true)
	default:
		c.sync(cloudsync.Ask, false)
		c.refreshProfile(false)
	}
	return c
}

// signedIn reports whether a Mon account is signed in.
func (c *account) signedIn() bool {
	return c.client.Token != "" && c.engine.State().UserID != ""
}

// name is the person's name as Mon has it, else their email.
func (c *account) name() string {
	st := c.engine.State()
	return cmp.Or(st.Name, st.Email, st.UserID)
}

// email is the person's email, "" when name already says it.
func (c *account) email() string {
	st := c.engine.State()
	if st.Email == c.name() {
		return ""
	}
	return st.Email
}

// notify shows the account as it is now, in the menu bar menu and
// Settings.
func (c *account) notify() {
	c.a.rebuildTray()
	if c.a.settingsWin != nil {
		c.a.settingsWin.Invalidate()
	}
}

// refreshProfile takes the person's name and email as the account has
// them now, which they may have changed since signing in. adopt starts
// syncing for the account of a token whose account was forgotten.
func (c *account) refreshProfile(adopt bool) {
	client := *c.client
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		u, err := client.Me(ctx)
		mygo.RunOnMain(func() {
			if client.Token != c.client.Token {
				return
			}
			switch {
			case errors.Is(err, mon.ErrUnauthorized):
				c.forget()
			case err != nil:
			case adopt:
				if c.engine.SignedIn(u) == nil {
					c.sync(cloudsync.Ask, false)
				}
				c.notify()
			case c.engine.Refreshed(u) == nil:
				c.notify()
			}
		})
	}()
}

// deviceName is how Mon lists Trot signed in on this Mac: its name, as in
// Sharing settings. A development build signs in apart from the release,
// and says so.
func deviceName() string {
	name := ""
	if out, err := exec.Command("/usr/sbin/scutil", "--get", "ComputerName").Output(); err == nil {
		name = strings.TrimSpace(string(out))
	}
	if name == "" {
		host, _ := os.Hostname()
		name = cmp.Or(strings.TrimSuffix(host, ".local"), "Mac")
	}
	if mygo.IsDev() {
		name += " (dev)"
	}
	return name
}

// signIn signs in to Mon: it opens Mon's page to approve the code, which
// Settings shows, and syncs once the person approved it.
func (c *account) signIn() {
	if c.signin != nil {
		c.signin.cancel()
	}
	ctx, cancel := context.WithCancel(context.Background())
	si := &signin{cancel: cancel}
	c.signin, c.signInErr = si, ""
	c.notify()
	// The goroutine has clients of its own: the main thread sets the
	// token of c's.
	old, client := *c.client, *c.client
	client.Token = ""
	go func() {
		// A token still kept is signed out first, so Mon doesn't list it on.
		if old.Token != "" {
			lctx, lcancel := context.WithTimeout(ctx, 10*time.Second)
			old.Logout(lctx)
			lcancel()
		}
		dc, err := client.StartDeviceLogin(ctx, cloudsync.App, deviceName())
		if err != nil {
			mygo.RunOnMain(func() { c.signInDone(si, ctx, err) })
			return
		}
		mygo.RunOnMain(func() {
			if c.signin != si {
				return
			}
			si.code, si.url = dc.UserCode, dc.VerificationURIComplete
			mygo.Shell.OpenExternal(dc.VerificationURIComplete)
			c.notify()
		})
		token, err := client.WaitForDeviceToken(ctx, dc)
		var u *mon.User
		if err == nil {
			client.Token = token
			u, err = client.Me(ctx)
		}
		mygo.RunOnMain(func() {
			if err == nil && c.signin == si {
				c.client.Token = token
				c.a.s.SetMonToken(token)
				err = c.engine.SignedIn(u)
				c.asked = false
				c.sync(cloudsync.Ask, false)
			}
			c.signInDone(si, ctx, err)
		})
	}()
}

// signInDone ends the sign-in si, saying why it failed, unless it was
// cancelled.
func (c *account) signInDone(si *signin, ctx context.Context, err error) {
	if c.signin != si {
		return
	}
	c.signin = nil
	si.cancel()
	switch {
	case err == nil, ctx.Err() != nil:
	case errors.Is(err, mon.ErrAccessDenied):
		c.signInErr = "The sign-in was declined."
	case errors.Is(err, mon.ErrExpired):
		c.signInErr = "The code expired before it was approved. Sign in again."
	default:
		c.signInErr = "Couldn't sign in: " + monError(err)
	}
	c.notify()
}

// cancelSignIn stops waiting for the sign-in's approval.
func (c *account) cancelSignIn() {
	if si := c.signin; si != nil {
		c.signin = nil
		si.cancel()
		c.notify()
	}
}

// signOut stops syncing and revokes the token on Mon.
func (c *account) signOut() {
	client := *c.client
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		client.Logout(ctx)
	}()
	c.forget()
}

// forget forgets the account and its token, as signed out.
func (c *account) forget() {
	if c.push != nil {
		c.push.Stop()
		c.push = nil
	}
	if c.retry != nil {
		c.retry.Stop()
		c.retry = nil
	}
	c.failure, c.failures, c.retryAt = "", 0, time.Time{}
	c.client.Token = ""
	c.a.s.SetMonToken("")
	c.engine.Forget()
	c.notify()
}

// sessionEnded forgets the account whose token Mon no longer takes, as
// one signed out from the account page.
func (c *account) sessionEnded() {
	if c.client.Token != "" {
		c.forget()
	}
}

// changed saves this Mac's settings to the account a moment after they
// change.
func (c *account) changed() {
	if !c.signedIn() {
		return
	}
	if c.push != nil {
		c.push.Stop()
	}
	c.push = time.AfterFunc(pushDelay, func() {
		mygo.RunOnMain(func() {
			c.push = nil
			c.run(false, c.engine.Push)
		})
	})
}

// pull asks the account for changes, unless it was asked a moment ago.
func (c *account) pull() {
	if time.Since(c.lastPull) > pullEvery {
		c.sync(cloudsync.Ask, false)
	}
}

// sync merges the account's settings with this Mac's, the first time as
// choice says. manual asks again whose settings to keep, as Sync Now does.
func (c *account) sync(choice cloudsync.Choice, manual bool) {
	if !c.signedIn() {
		return
	}
	c.lastPull = time.Now()
	c.run(manual, func(ctx context.Context) (cloudsync.Result, error) { return c.engine.Sync(ctx, choice) })
}

// run runs a sync off the main thread, showing that it does.
func (c *account) run(manual bool, job func(context.Context) (cloudsync.Result, error)) {
	c.busy++
	if c.retry != nil {
		c.retry.Stop()
		c.retry = nil
	}
	c.notify()
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		_, err := job(ctx)
		mygo.RunOnMain(func() {
			c.busy--
			c.done(err, manual)
			c.notify()
		})
	}()
}

// done notes a sync's outcome, and asks whose settings to keep when a
// first sync needs to know.
func (c *account) done(err error, manual bool) {
	if err == nil || errors.Is(err, cloudsync.ErrNeedsChoice) || errors.Is(err, cloudsync.ErrStale) {
		c.failure, c.failures, c.retryAt = "", 0, time.Time{}
	}
	switch {
	case err == nil, errors.Is(err, cloudsync.ErrStale):
		// Stale: the settings kept changing as it synced, and the push of
		// the last change syncs them.
	case errors.Is(err, cloudsync.ErrNeedsChoice):
		if c.asked && !manual {
			return
		}
		c.asked = true
		c.askChoice()
	case errors.Is(err, mon.ErrUnauthorized):
		// Signed out elsewhere, as from the account page.
		c.forget()
	default:
		// Offline, most likely: nothing is lost, and the next sync merges
		// what this one did not.
		c.failure = monError(err)
		c.retryAt = time.Now().Add(syncRetryDelay(c.failures))
		c.failures++
		c.retry = time.AfterFunc(time.Until(c.retryAt), func() {
			mygo.RunOnMain(func() {
				c.retry = nil
				c.sync(cloudsync.Ask, false)
			})
		})
	}
}

// askChoice asks whose settings a first sync keeps, where both this Mac
// and the account have their own.
func (c *account) askChoice() {
	mygo.App.Focus()
	go func() {
		res, err := mygo.Dialog.Message(mygo.MessageOptions{
			Type:    mygo.MessageQuestion,
			Message: "Sync Trot's settings with your Mon account?",
			Detail: "This Mac and your account both have settings of their own. " +
				"Choose which to keep; the other's are replaced. API keys stay on this Mac.",
			Buttons:       []string{"Use the Account's", "Use This Mac's", "Not Now"},
			DefaultButton: 0,
			CancelButton:  2,
		})
		if err != nil {
			return
		}
		mygo.RunOnMain(func() {
			switch res.Button {
			case 0:
				c.sync(cloudsync.UseAccount, true)
			case 1:
				c.sync(cloudsync.UseLocal, true)
			}
		})
	}()
}

// flush saves a change waiting to go to the account, as Trot quits,
// waiting for it a moment at most.
func (c *account) flush() {
	if c.push == nil || !c.push.Stop() || !c.signedIn() {
		return
	}
	done := make(chan struct{})
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), quitPush)
		defer cancel()
		c.engine.Push(ctx)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(quitPush + 250*time.Millisecond):
	}
}

// syncStatus is how settings sync is, in a line: syncing, when it last
// synced, or why it failed.
func (c *account) syncStatus() string {
	st := c.engine.State()
	switch {
	case c.busy > 0:
		return "Syncing settings…"
	case c.failure != "":
		return "Settings sync failed: " + c.failure + ". Trying again at " + c.retryAt.Format("15:04") + "."
	case st.Base == nil:
		return "Settings haven't synced yet."
	}
	return "Settings synced " + when(st.SyncedAt) + "."
}

// when is a past time in words: just now, at a time today, or on a day.
func when(t time.Time) string {
	now := time.Now()
	switch {
	case now.Sub(t) < time.Minute:
		return "just now"
	case t.YearDay() == now.YearDay() && t.Year() == now.Year():
		return "at " + t.Format("15:04")
	}
	return "on " + t.Format("Jan 2")
}

// monError says why a request to Mon failed, in words for the person
// rather than the network's.
func monError(err error) string {
	host := service.MonURL()
	if u, perr := url.Parse(host); perr == nil && u.Host != "" {
		host = u.Host
	}
	var me *mon.Error
	var ne net.Error
	switch {
	case errors.As(err, &me) && me.Status >= 500:
		return host + " is having trouble"
	case errors.As(err, &me) && me.Code == "invalid_client":
		return host + " doesn't know Trot yet"
	case errors.As(err, &ne), errors.Is(err, context.DeadlineExceeded), errors.Is(err, io.ErrUnexpectedEOF):
		return "can't reach " + host
	}
	return err.Error()
}

// syncLocal is this Mac's settings as settings sync reads and writes them.
// Settings are safe to use from the engine's goroutine.
type syncLocal struct{ s *settings.Settings }

func (l syncLocal) Read() (cloudsync.Snapshot, error) { return l.s.Synced(), nil }

func (l syncLocal) Apply(read, s cloudsync.Snapshot) error {
	if !l.s.ApplySynced(read, s) {
		return cloudsync.ErrStale
	}
	return nil
}

func (l syncLocal) IsDefault(s cloudsync.Snapshot) bool { return settings.IsDefaultSynced(s) }

func (l syncLocal) Known(key string) bool { return settings.KnowsSynced(key) }
