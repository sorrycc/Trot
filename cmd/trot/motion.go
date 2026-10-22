package main

import (
	"time"

	"github.com/egoist/mygo/ui"
)

// The interface's motion: short, easing out, so it never holds up reading.
// While the desktop asks for less motion, values go to their targets at
// once and colors still change smoothly.
var (
	// hoverAnim changes a control's fill under the mouse.
	hoverAnim = ui.Animation{Duration: 120 * time.Millisecond}
	// enterAnim brings in what appears: the panel's card, a result, a
	// notice, a Settings pane.
	enterAnim = ui.Animation{Duration: 220 * time.Millisecond}
	// pressAnim shrinks a button a little as it is pressed, and lets it
	// spring back.
	pressAnim = ui.Animation{Spring: ui.SpringOptions{Duration: 250 * time.Millisecond, Bounce: 0.3}}
	// turnAnim turns a chevron as its menu opens and closes.
	turnAnim = ui.Animation{Spring: ui.SpringOptions{Duration: 300 * time.Millisecond}}
	// settingsResize is how long, in seconds, Settings takes to fit a
	// pane of another height.
	settingsResize = 0.2
	// swap replaces an icon or a line of text, as copy's check does.
	swap = ui.ContentTransition{}
)

// entrance eases el in, rising rise DIPs as it fades in, whenever current
// differs from what *shown holds: once for each new thing el shows. It
// animates el's opacity and offset rather than its layout, so the window
// growing around it doesn't cut it short.
func entrance(el ui.Element, shown *any, current any, rise float32) {
	if *shown != current {
		*shown = current
		el.Jump("in", 0)
	}
	if k := el.AnimateTo("in", 1, enterAnim); k < 1 {
		el.Opacity(k).Translate(0, rise*(1-k))
	}
}

// pressScale shrinks a pressed button to 94% around its center, springing
// back as it is let go.
func pressScale(b ui.Element, pressed bool) {
	target := float32(1)
	if pressed {
		target = 0.94
	}
	if s := b.AnimateTo("press", target, pressAnim); s != 1 {
		b.Scale(s, s)
	}
}
