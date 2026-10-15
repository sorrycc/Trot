//go:build darwin

package mac

import (
	"github.com/ebitengine/purego"
	"github.com/ebitengine/purego/objc"
)

// Helpers for the panel's NSWindow, which MyGo leaves square and sizes
// without animation. Call them on the main thread with the window's
// NativeHandle.

type nsRect struct{ X, Y, W, H float64 }

var (
	msgSetDouble func(obj id, sel objc.SEL, v float64)
	msgGetRect   func(obj id, sel objc.SEL) nsRect
	msgSetFrame  func(obj id, sel objc.SEL, r nsRect, display bool)
	windowOnce   bool
)

func loadWindow() {
	load()
	if windowOnce {
		return
	}
	windowOnce = true
	_, _ = purego.Dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", purego.RTLD_GLOBAL|purego.RTLD_NOW)
	purego.RegisterFunc(&msgSetDouble, msgSendAddr)
	purego.RegisterFunc(&msgGetRect, msgSendAddr)
	purego.RegisterFunc(&msgSetFrame, msgSendAddr)
}

// RoundCorners rounds the window's content to radius, so the vibrancy
// behind it and the window's shadow follow a card's corners.
func RoundCorners(window uintptr, radius float64) {
	withPool(func() {
		loadWindow()
		win := id(window)
		view := send(win, "contentView")
		if view == 0 {
			return
		}
		send(view, "setWantsLayer:", 1)
		layer := send(view, "layer")
		if layer == 0 {
			return
		}
		msgSetDouble(layer, sel("setCornerRadius:"), radius)
		if sendBool(layer, "respondsToSelector:", uintptr(sel("setCornerCurve:"))) {
			send(layer, "setCornerCurve:", uintptr(nsString("continuous")))
		}
		send(layer, "setMasksToBounds:", 1)
		send(win, "setOpaque:", 0)
		send(win, "setHasShadow:", 1)
		send(win, "invalidateShadow")
	})
}

// InvalidateShadow casts the window's shadow again for its new shape.
func InvalidateShadow(window uintptr) {
	withPool(func() { send(id(window), "invalidateShadow") })
}

// primaryHeight is the height of the screen whose bottom left is the
// origin of AppKit's coordinates.
func primaryHeight() float64 {
	screens := send(class("NSScreen"), "screens")
	if sendInt(screens, "count") == 0 {
		return 0
	}
	return msgGetRect(send(screens, "firstObject"), sel("frame")).H
}

// AnimateFrame moves and resizes the window to a rectangle given from the
// top left of the primary display, in points, over duration seconds with
// an ease out; at once when duration is 0. A new call during the
// animation takes it over.
func AnimateFrame(window uintptr, x, y, w, h, duration float64) {
	withPool(func() {
		loadWindow()
		win := id(window)
		r := nsRect{x, primaryHeight() - y - h, w, h}
		if duration <= 0 {
			msgSetFrame(win, sel("setFrame:display:"), r, true)
			return
		}
		animate(duration, func() { msgSetFrame(send(win, "animator"), sel("setFrame:display:"), r, true) })
	})
}

// AnimateAlpha fades the window to alpha over duration seconds.
func AnimateAlpha(window uintptr, alpha, duration float64) {
	withPool(func() {
		loadWindow()
		win := id(window)
		if duration <= 0 {
			msgSetDouble(win, sel("setAlphaValue:"), alpha)
			return
		}
		animate(duration, func() { msgSetDouble(send(win, "animator"), sel("setAlphaValue:"), alpha) })
	})
}

func animate(duration float64, fn func()) {
	ctx := class("NSAnimationContext")
	send(ctx, "beginGrouping")
	current := send(ctx, "currentContext")
	msgSetDouble(current, sel("setDuration:"), duration)
	if hasClass("CAMediaTimingFunction") {
		ease := send(class("CAMediaTimingFunction"), "functionWithName:", uintptr(nsString("easeOut")))
		send(current, "setTimingFunction:", uintptr(ease))
	}
	fn()
	send(ctx, "endGrouping")
}

// MonitorClicks calls fn on the main thread for every mouse press in
// another app, until stop is called. Presses in the app's own windows
// never reach it.
func MonitorClicks(fn func()) (stop func()) {
	var monitor id
	var block objc.Block
	withPool(func() {
		const mask = 1<<1 | 1<<3 | 1<<25 // left, right and other mouse down
		block = objc.NewBlock(func(_ objc.Block, _ id) { fn() })
		monitor = send(class("NSEvent"), "addGlobalMonitorForEventsMatchingMask:handler:", mask, uintptr(block))
		if monitor != 0 {
			send(monitor, "retain")
		}
	})
	return func() {
		withPool(func() {
			if monitor != 0 {
				send(class("NSEvent"), "removeMonitor:", uintptr(monitor))
				send(monitor, "release")
				monitor = 0
			}
			if block != 0 {
				block.Release()
				block = 0
			}
		})
	}
}

// WindowNumber is the window's number in the window server, which
// screencapture -l takes.
func WindowNumber(window uintptr) int {
	var n int
	withPool(func() { n = sendInt(id(window), "windowNumber") })
	return n
}
