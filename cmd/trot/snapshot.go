package main

import (
	"fmt"
	"os"
	"time"

	"github.com/egoist/mygo"

	"trot/internal/mac"
)

// snapshot captures a window once it settles, for checking the real
// window from a script, and quits: TROT_SNAPSHOT=out.png captures the
// panel, or Settings with TROT_SNAPSHOT_WINDOW=settings. The window's
// number goes to out.png.id, for screencapture -l, which shows the
// vibrancy behind it too, and its bounds to out.png.bounds.
func (a *trotApp) snapshot(out string) {
	go func() {
		time.Sleep(3 * time.Second)
		mygo.RunOnMain(func() {
			win := a.pw.win
			if os.Getenv("TROT_SNAPSHOT_WINDOW") == "settings" && a.settingsWin != nil {
				win = a.settingsWin
			}
			if png, err := win.CapturePage(); err == nil {
				os.WriteFile(out, png, 0o644)
			}
			b := win.Bounds()
			os.WriteFile(out+".bounds", []byte(fmt.Sprintf("%d %d %d %d", b.X, b.Y, b.Width, b.Height)), 0o644)
			os.WriteFile(out+".id", []byte(fmt.Sprint(mac.WindowNumber(win.NativeHandle()))), 0o644)
		})
		if os.Getenv("TROT_SNAPSHOT_KEEP") == "" {
			time.Sleep(500 * time.Millisecond)
			mygo.App.Quit()
		}
	}()
}
