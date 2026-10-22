package main

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestCrashed(t *testing.T) {
	header := crashHeader(time.Now())
	if crashed([]byte(header)) || !crashed([]byte(header+"panic: boom\n")) || !crashed([]byte("fatal error: old log")) {
		t.Error("only a log with more than its header is a crash")
	}
}

func TestCrashReport(t *testing.T) {
	home, _ := os.UserHomeDir()
	log := "Trot 0.5.1 darwin/arm64 go1.27.1, started 2026-10-22T08:00:00Z\n\npanic: boom\n\t" + home + "/x.go:1\n\t/Users/someone/y.go:2\n\t/Users/Shared/z.go:3\n"
	c := crashReport("2026-10-22-091500.log", log)
	if c.App != "trot" || c.Version != "0.5.1" || c.Runtime != "go1.27.1" || c.OS != "darwin" || c.Arch != "arm64" || c.Kind != "fatal" {
		t.Errorf("%+v", c)
	}
	if want := time.Date(2026, 10, 22, 9, 15, 0, 0, time.Local).Unix(); c.OccurredAt != want {
		t.Errorf("occurred at %d, want %d", c.OccurredAt, want)
	}
	if strings.Contains(c.Log, "someone") || strings.Contains(c.Log, home) || !strings.Contains(c.Log, "~/x.go") || !strings.Contains(c.Log, "/Users/Shared/z.go") {
		t.Errorf("home folders stay out: %s", c.Log)
	}
}
