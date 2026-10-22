package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"time"

	"github.com/egoist/mygo"

	"trot/internal/cloudsync"
	"trot/internal/mon"
	"trot/internal/service"
)

// maxCrashReport is how much of a crash log a report sends: Mon takes
// 256 KB, which the log, escaped in JSON, stays under.
const maxCrashReport = 192 << 10

// The states of a crash log, as its name ends: .log not sent yet,
// .sent.log sent and .unsent.log one Mon won't take.
const (
	crashSent   = ".sent.log"
	crashUnsent = ".unsent.log"
)

// sendsCrashes reports whether this build sends crash reports: a release,
// which updates itself, or one TROT_MON_URL points at a Mon to try them
// with.
func sendsCrashes() bool {
	return os.Getenv("TROT_MON_URL") != "" || mygo.Updater.Enabled()
}

// sendCrashes sends the crash logs of dir's crashes folder that haven't
// been, to Mon, anonymously, and marks each sent, or unsent when Mon won't
// take it. When Mon can't be reached, the rest wait for the next launch.
func sendCrashes(dir string) {
	if !sendsCrashes() {
		return
	}
	crashes := filepath.Join(dir, "crashes")
	entries, _ := os.ReadDir(crashes)
	var names []string
	for _, e := range entries {
		n := e.Name()
		if !e.IsDir() && strings.HasSuffix(n, ".log") && !strings.HasSuffix(n, crashSent) && !strings.HasSuffix(n, crashUnsent) {
			names = append(names, n)
		}
	}
	slices.Sort(names)
	c := mon.New(service.MonURL())
	for _, name := range names {
		path := filepath.Join(crashes, name)
		b, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		err = c.SendCrash(ctx, crashReport(name, string(b)))
		cancel()
		stem := strings.TrimSuffix(path, ".log")
		var me *mon.Error
		switch {
		case err == nil:
			os.Rename(path, stem+crashSent)
		case errors.As(err, &me) && me.Status == http.StatusBadRequest:
			os.Rename(path, stem+crashUnsent)
		default:
			return
		}
	}
}

// crashReport is the report of the log named name: of the version and
// system that crashed, as the log's header says, which may be older than
// this one.
func crashReport(name, log string) mon.Crash {
	c := mon.Crash{
		App: cloudsync.App, Version: appVersion(), OS: runtime.GOOS, Arch: runtime.GOARCH, Runtime: runtime.Version(),
		Kind: mon.CrashFatal, Log: redactHome(log),
	}
	if len(name) >= len(crashTime) {
		if at, err := time.ParseInLocation(crashTime, name[:len(crashTime)], time.Local); err == nil {
			c.OccurredAt = at.Unix()
		}
	}
	first, _, _ := strings.Cut(log, "\n")
	if f := strings.Fields(first); len(f) >= 4 && f[0] == "Trot" {
		// crashHeader's line.
		c.Version, c.Runtime = f[1], strings.TrimSuffix(f[3], ",")
		if goos, arch, ok := strings.Cut(f[2], "/"); ok {
			c.OS, c.Arch = goos, arch
		}
	}
	if len(c.Log) > maxCrashReport {
		// The goroutine that crashed comes first.
		c.Log = strings.ToValidUTF8(c.Log[:maxCrashReport], "")
	}
	return c
}
