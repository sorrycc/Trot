// Package ocr lets the user pick a screen region with the system crosshair
// and reads its text.
package ocr

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"trot/internal/mac"
)

var (
	// ErrNoText is a screenshot without text.
	ErrNoText = errors.New("No text found in the screenshot.")
	// ErrDenied is a missing Screen Recording permission.
	ErrDenied = errors.New("Allow Screen Recording for Trot in System Settings, then open Trot again.")
)

// Capture runs the system's crosshair and returns the screenshot the user
// drew as a file for Recognize, or "" when they cancelled with Escape.
func Capture(ctx context.Context) (string, error) {
	// Without the permission screencapture still runs, but the image holds
	// only the wallpaper, so the failure would look like no text.
	if !mac.ScreenCaptureAllowed() {
		mac.RequestScreenCapture()
		return "", ErrDenied
	}
	b := make([]byte, 8)
	rand.Read(b)
	file := filepath.Join(os.TempDir(), "trot-"+hex.EncodeToString(b)+".png")
	// -i draws the selection UI, -x keeps it quiet.
	err := exec.CommandContext(ctx, "/usr/sbin/screencapture", "-i", "-x", "-t", "png", file).Run()
	if _, statErr := os.Stat(file); statErr != nil {
		// Escape leaves no file and exits 1; anything else is a failure.
		var exit *exec.ExitError
		if err != nil && (!errors.As(err, &exit) || exit.ExitCode() > 1) {
			return "", fmt.Errorf("The screenshot failed (%v).", err)
		}
		return "", nil
	}
	return file, nil
}

// Discard drops a capture that is no longer wanted.
func Discard(file string) { os.Remove(file) }

// Recognize returns the text in the screenshot, joined into paragraphs,
// and deletes the file.
func Recognize(file string) (string, error) {
	defer Discard(file)
	lines, err := mac.RecognizeText(file)
	if err != nil {
		return "", err
	}
	text := JoinLines(lines)
	if text == "" {
		return "", ErrNoText
	}
	return text, nil
}

// JoinLines makes the lines of one paragraph one line: Chinese and
// Japanese join directly, everything else, Korean included, with a space.
// A line ending in sentence punctuation keeps its break.
func JoinLines(lines []string) string {
	var b strings.Builder
	var last rune
	for _, line := range lines {
		t := strings.TrimSpace(line)
		if t == "" {
			continue
		}
		first := []rune(t)[0]
		switch {
		case b.Len() == 0:
		case strings.ContainsRune(".!?。！？:：", last):
			b.WriteByte('\n')
		case joinsWithoutSpace(last) || joinsWithoutSpace(first):
		default:
			b.WriteByte(' ')
		}
		b.WriteString(t)
		r := []rune(t)
		last = r[len(r)-1]
	}
	return b.String()
}

// joinsWithoutSpace: Han, kana and CJK punctuation, scripts written
// without spaces.
func joinsWithoutSpace(r rune) bool {
	switch {
	case r >= 0x3040 && r <= 0x30FF, r >= 0x3400 && r <= 0x4DBF, r >= 0x4E00 && r <= 0x9FFF,
		r >= 0x3000 && r <= 0x303F, r >= 0xFF00 && r <= 0xFFEF:
		return true
	}
	return false
}
