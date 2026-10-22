package main

import (
	"bytes"
	"cmp"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"runtime/debug"
	"slices"
	"strings"
	"time"

	"github.com/egoist/mygo"
)

// maxCrashes is how many crash logs the crashes folder keeps.
const maxCrashes = 10

// crashTime names a crash log by the time of the crash.
const crashTime = "2006-01-02-150405"

// keepCrashes has the runtime write the panic or fatal error that ends
// the app, with every goroutine's stack, to crash.log in dir as well as
// to stderr, which nothing keeps when the app starts from the Finder or
// the Dock. crash.log starts with a line of the app's version and system,
// which the crash follows. A crash.log a crash left is moved first into
// the crashes folder, named by its time, with the home folder taken out,
// so that each launch starts an empty one.
func keepCrashes(dir string) {
	if dir == "" {
		return
	}
	path := filepath.Join(dir, "crash.log")
	if fi, err := os.Stat(path); err == nil {
		crashes := filepath.Join(dir, "crashes")
		if b, err := os.ReadFile(path); err == nil && crashed(b) && os.MkdirAll(crashes, 0o755) == nil {
			name := filepath.Join(crashes, fi.ModTime().Format(crashTime)+".log")
			if os.WriteFile(name, []byte(redactHome(string(b))), 0o644) == nil {
				os.Chtimes(name, fi.ModTime(), fi.ModTime())
			}
			pruneCrashes(crashes)
		}
	}
	os.MkdirAll(dir, 0o755)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return
	}
	// The runtime writes from where the line ends.
	f.WriteString(crashHeader(time.Now()))
	debug.SetCrashOutput(f, debug.CrashOptions{})
	f.Close() // SetCrashOutput keeps its own copy
}

// crashHeader is the line a crash log starts with: what crashed, on what,
// and since when.
func crashHeader(started time.Time) string {
	return fmt.Sprintf("Trot %s %s/%s %s, started %s\n\n", appVersion(), runtime.GOOS, runtime.GOARCH,
		runtime.Version(), started.UTC().Format(time.RFC3339))
}

func appVersion() string { return cmp.Or(mygo.App.Version(), "dev") }

// crashed reports whether a crash.log holds a crash, more than its
// header.
func crashed(b []byte) bool {
	if bytes.HasPrefix(b, []byte("Trot ")) {
		_, b, _ = bytes.Cut(b, []byte("\n\n"))
	}
	return len(bytes.TrimSpace(b)) > 0
}

// pruneCrashes removes all but the newest maxCrashes logs of dir.
func pruneCrashes(dir string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	var names []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".log") {
			names = append(names, e.Name())
		}
	}
	slices.Sort(names)
	for len(names) > maxCrashes {
		os.Remove(filepath.Join(dir, names[0]))
		names = names[1:]
	}
}

// homePath matches a home folder in a path.
var homePath = regexp.MustCompile(`/Users/[^/\s"':]+`)

// redactHome takes the home folders out of a crash log, as ~, so that a
// report says nothing of whose it is. /Users/Shared is no one's.
func redactHome(log string) string {
	if home, err := os.UserHomeDir(); err == nil && len(home) > 1 {
		log = strings.ReplaceAll(log, home, "~")
	}
	return homePath.ReplaceAllStringFunc(log, func(m string) string {
		if m == "/Users/Shared" {
			return m
		}
		return "~"
	})
}
