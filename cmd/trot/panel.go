package main

import (
	"math"
	"strings"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"trot/internal/lang"
	"trot/internal/service"
	"trot/internal/settings"
)

// The panel's measures, in DIPs.
const (
	panelWidth  = 440
	panelInset  = 16
	panelRadius = 18
	// sourceCap is how much of the source the result mode shows; the rest
	// scrolls.
	sourceCap = 110
)

type panelMode int

const (
	modeResult panelMode = iota
	// modeInput has an editable source, which Return translates.
	modeInput
)

// action is a button under a notice.
type action struct {
	label string
	run   func()
}

// notice is an error or a hint in place of the result.
type notice struct {
	message string
	isError bool
	action  *action
}

// panelHost is the window that shows the panel: the floating panel, or a
// tester's stand-in.
type panelHost interface {
	// present shows the panel near point, taking the keyboard with key. A
	// panel already showing stays where it is.
	present(point mygo.Point, key bool)
	// dismiss fades the panel out.
	dismiss()
	// fit sizes the panel to the card's height, keeping its top still.
	fit(height int)
	visible() bool
	key() bool
	// room is the height of the work area the panel is on.
	room() int
	// popup shows a menu below a point of the panel, and calls done once
	// it closes.
	popup(m *mygo.Menu, x, y int, done func())
	// update runs fn on the main thread and draws the panel again.
	update(fn func())
	reduceMotion() bool
}

// speaker reads text aloud.
type speaker interface {
	Speak(text, locale string)
	Stop()
	Speaking() bool
}

// panel is the floating card with the source text, the translation and a
// row of controls. One lives for the whole run and is shown at the mouse
// for each translation. In input mode the source is editable and Return
// translates it.
type panel struct {
	s    *settings.Settings
	host panelHost
	// newSpeaker makes the speaker on first use: the synthesizer loads
	// voices, which the panel's first appearance has no need of.
	newSpeaker func(onEnd func()) speaker
	speaker    speaker

	// onTranslate is Return in input mode, with the typed text.
	onTranslate func(text string)
	// onTargetChange is a target picked from the language chip.
	onTargetChange  func(l lang.Language)
	onServiceChange func(k service.Kind)
	// onClose is the user closing the panel; the translation can stop.
	onClose func()

	mode panelMode
	// reading is waiting for the selection or a screenshot: only the header
	// and the footer show, with what is being waited for.
	reading  bool
	detected lang.Language
	target   lang.Language
	// picked is a target the user picked from the chip, kept for the next
	// Return in input mode so the two-language rule doesn't take it back.
	picked  lang.Language
	service service.Kind

	source string
	// sourceGrey: the typed text was translated, so it steps back to grey
	// under the result until it is edited.
	sourceGrey bool
	result     string
	streaming  bool
	thinking   bool
	// lastChunk is when text last arrived: the caret stays solid while it
	// arrives and pulses once the stream goes quiet.
	lastChunk  time.Time
	showsError bool
	notice     *notice
	status     string
	pinned     bool
	copiedAt   time.Time
	// announcement waits for the next frame to reach screen readers.
	announcement string

	input        ui.Handle
	resultScroll ui.ScrollState
	sourceScroll ui.ScrollState
	// selected is the text selected in the panel in the last frame, for
	// the selection hotkey while the panel has the keyboard.
	selected string
	// chips are where the chips were in the last frame, for their menus.
	langChip, serviceChip ui.Rect
	menuOpen              string
	fitted                int
}

func newPanel(s *settings.Settings) *panel {
	return &panel{s: s, target: s.FirstLanguage(), service: s.Service()}
}

// begin shows the source and clears the result, ready for append.
func (p *panel) begin(source string, detected, target lang.Language, k service.Kind, point mygo.Point) {
	p.mode = modeResult
	p.reading = false
	p.picked = ""
	p.detected, p.target = detected, target
	p.source = source
	p.sourceScroll = ui.ScrollState{}
	p.startResult(k)
	p.notice = nil
	p.present(point, true)
}

// beginReading shows only the header and status, while the selection or a
// screenshot is being read. key false leaves the keyboard with the app in
// front, which a synthesized ⌘C needs.
func (p *panel) beginReading(status string, point mygo.Point, key bool) {
	p.mode = modeResult
	p.reading = true
	p.detected = ""
	p.source = ""
	p.clearResult()
	p.showsError = false
	p.notice = nil
	p.status = status
	p.present(point, key)
}

// showInput opens with an editable source. hint shows as a notice under
// it, with act as a button.
func (p *panel) showInput(point mygo.Point, hint string, act *action) {
	fresh := !p.host.visible() || p.mode != modeInput
	p.mode = modeInput
	p.reading = false
	p.showsError = false
	p.detected = ""
	if fresh {
		p.picked = ""
		p.target = p.s.FirstLanguage()
		p.source = ""
		p.clearResult()
	}
	// Text left grey by its translation is the draft again.
	p.sourceGrey = false
	p.status = "↩ Translate   ⇧↩ New line"
	if hint != "" {
		p.notice = &notice{message: hint, action: act}
	} else {
		p.notice = nil
	}
	p.present(point, true)
	p.input.Focus()
}

// beginInInput starts a translation of the typed text while staying in
// input mode. The typed text steps back to grey, so the result stands out.
func (p *panel) beginInInput(k service.Kind) {
	p.sourceGrey = true
	p.startResult(k)
	p.notice = nil
}

func (p *panel) setLanguages(detected, target lang.Language) {
	p.detected, p.target = detected, target
}

// showError shows an error in place of the result, with act as a button
// under it. In result mode Return presses the button. A result that
// arrived before it, as a cut-off one did, stays.
func (p *panel) showError(message string, act *action) {
	p.showsError = true
	p.reading = false
	p.endStreaming()
	p.status = ""
	p.notice = &notice{message: message, isError: true, action: act}
	p.announcement = message
}

// hide takes the panel off the screen without a word to the owner, for
// when the owner is about to show it again or needs it out of the way.
func (p *panel) hide() {
	if !p.host.visible() {
		return
	}
	p.reading = false
	p.dismiss(false)
}

// cancelStreaming: the stream was stopped by a newer action. What arrived
// stays; a panel still waiting for its text has nothing to keep and goes.
func (p *panel) cancelStreaming() {
	if p.reading {
		p.reading = false
		p.dismiss(false)
		return
	}
	if !p.streaming {
		return
	}
	p.endStreaming()
	p.status = "Stopped"
}

func (p *panel) append(chunk string) {
	if chunk == "" {
		return
	}
	if p.thinking {
		p.thinking = false
		p.status = "Translating…"
	}
	p.result += chunk
	p.lastChunk = time.Now()
}

// showThinking says in the footer that the model reasons before it
// answers, so a long wait with nothing in it doesn't look stuck.
func (p *panel) showThinking() {
	if !p.streaming || p.result != "" {
		return
	}
	p.thinking = true
	p.status = "Thinking…"
}

// finish ends the stream; status goes in the footer.
func (p *panel) finish(status string) {
	p.endStreaming()
	p.status = status
	p.announcement = p.result
}

func (p *panel) startResult(k service.Kind) {
	p.showsError = false
	p.reading = false
	p.clearResult()
	p.streaming = true
	p.service = k
	p.status = "Translating…"
}

func (p *panel) clearResult() {
	if p.speaker != nil {
		p.speaker.Stop()
	}
	p.result = ""
	p.streaming = false
	p.thinking = false
	p.lastChunk = time.Time{}
	p.resultScroll = ui.ScrollState{}
}

func (p *panel) endStreaming() {
	p.streaming = false
	p.thinking = false
}

func (p *panel) present(point mygo.Point, key bool) {
	p.host.present(point, key)
}

// close is the user closing the panel.
func (p *panel) close() { p.dismiss(true) }

// dismiss fades the panel out; notify tells the owner, which stops the
// translation.
func (p *panel) dismiss(notify bool) {
	if p.speaker != nil {
		p.speaker.Stop()
	}
	// The owner stops the request; the panel's side of it ends here, or a
	// panel shown again mid-fade would still count as streaming.
	p.endStreaming()
	p.pinned = false
	if notify && p.onClose != nil {
		p.onClose()
	}
	p.host.dismiss()
}

// outsideClick is a click in another app: it closes the panel unless it
// is pinned or takes typing.
func (p *panel) outsideClick() {
	if p.pinned || p.mode == modeInput || !p.host.visible() {
		return
	}
	p.close()
}

// selectedText is the text selected in the panel, for the selection
// hotkey while the panel has the keyboard.
func (p *panel) selectedText() string {
	return strings.TrimSpace(strings.ReplaceAll(p.selected, caretText, ""))
}

func (p *panel) sourceText() string { return p.source }

func (p *panel) pick(k service.Kind) {
	if k == p.s.Service() {
		return
	}
	p.service = k
	if p.onServiceChange != nil {
		p.onServiceChange(k)
	}
}

func (p *panel) pickTarget(l lang.Language) {
	// Picking the target already shown still pins it for the next Return.
	p.picked = l
	if l == p.target {
		return
	}
	p.target = l
	if p.onTargetChange != nil {
		p.onTargetChange(l)
	}
}

func (p *panel) copyResult(c *ui.Context) {
	if p.result == "" {
		return
	}
	c.WriteClipboard(p.result)
	p.copiedAt = time.Now()
}

func (p *panel) toggleSpeech() {
	if p.speaker != nil && p.speaker.Speaking() {
		p.speaker.Stop()
		return
	}
	if p.speaker == nil && p.newSpeaker != nil {
		p.speaker = p.newSpeaker(func() { p.host.update(func() {}) })
	}
	if p.speaker != nil {
		p.speaker.Speak(p.result, p.target.SpeechLocale())
	}
}

func (p *panel) speaking() bool { return p.speaker != nil && p.speaker.Speaking() }

func (p *panel) languageMenu() *mygo.Menu {
	var items []*mygo.MenuItem
	for _, l := range lang.All {
		items = append(items, &mygo.MenuItem{Label: l.DisplayName(), Type: mygo.MenuItemCheckbox, Checked: l == p.target,
			Click: func(*mygo.MenuItem, *mygo.Window) { p.host.update(func() { p.pickTarget(l) }) }})
	}
	return mygo.NewMenu(items)
}

func (p *panel) serviceMenu() *mygo.Menu {
	var items []*mygo.MenuItem
	for i, k := range service.Kinds {
		items = append(items, &mygo.MenuItem{Label: k.DisplayName(), Type: mygo.MenuItemCheckbox, Checked: k == p.s.Service(),
			Accelerator: "Cmd+" + string(rune('1'+i)),
			Click:       func(*mygo.MenuItem, *mygo.Window) { p.host.update(func() { p.pick(k) }) }})
	}
	return mygo.NewMenu(items)
}

func (p *panel) showMenu(which string) {
	r := p.langChip
	m := p.languageMenu()
	if which == "service" {
		r = p.serviceChip
		m = p.serviceMenu()
	}
	p.menuOpen = which
	p.host.popup(m, int(r.X), int(r.Y+r.H+6), func() { p.menuOpen = "" })
}

// tint is the card's color over the vibrancy: it keeps the card its own
// color over a white page or a dark editor, and leaves a trace of what is
// behind.
func tint(t *ui.Theme) ui.Color {
	if t.Dark {
		return ui.RGBA(31, 31, 31, 0.6)
	}
	return ui.RGBA(255, 255, 255, 0.6)
}

func (p *panel) view(c *ui.Context) {
	t := c.Theme()
	if c.Vibrancy() {
		c.Root().Background(tint(t))
	} else {
		c.Root().Background(t.Background)
	}
	p.shortcuts(c)
	if p.announcement != "" {
		c.Announce(p.announcement)
		p.announcement = ""
	}

	card := ui.Column(c.Key("card")).Width(panelWidth).Shrink(0).Padding(12, panelInset).Gap(10).DragWindow()
	card.Children(func() {
		p.header(c)
		p.body(c)
		p.footer(c)
	})
	// The window follows the card's height, as it was laid out in the
	// last frame.
	if h := int(math.Ceil(float64(card.LayoutBounds().H))); h > 0 && h != p.fitted {
		p.fitted = h
		p.host.fit(h)
	}
}

// shortcuts: ⌘W closes, like a window. ⌘P pins, ⌘L opens the language
// menu and ⌘1 to ⌘4 pick a service, so the panel works without the mouse.
func (p *panel) shortcuts(c *ui.Context) {
	if c.Shortcut(ui.Cmd, ui.KeyW) {
		p.close()
	}
	if p.mode != modeInput && c.Shortcut(ui.Cmd, ui.KeyP) {
		p.pinned = !p.pinned
	}
	// The menu runs its own loop, so it opens once the frame is built.
	c.OnShortcut(ui.Cmd, ui.KeyL, func() { p.showMenu("language") })
	for i, k := range service.Kinds {
		if c.Shortcut(ui.Cmd, ui.Key1+ui.Key(i)) {
			p.pick(k)
		}
	}
	// In result mode Return presses the notice's button; in input mode
	// Return belongs to the field.
	if p.mode == modeResult && p.notice != nil && p.notice.action != nil && c.Shortcut(0, ui.KeyEnter) {
		p.notice.action.run()
	}
	// ⌘C with nothing selected copies the whole translation.
	if p.selected == "" && p.mode == modeResult && c.Shortcut(ui.Cmd, ui.KeyC) {
		p.copyResult(c)
	}
}

func (p *panel) header(c *ui.Context) {
	t := c.Theme()
	ui.Row(c).Height(22).Gap(4).Children(func() {
		from := "Auto"
		if p.detected != "" {
			from = p.detected.DisplayName()
		}
		lc := p.chip(c, "language", func() {
			ui.RichText(c,
				ui.Span{Text: from + " → ", Color: t.TextMuted},
				ui.Span{Text: p.target.DisplayName(), Color: t.Text},
			).SingleLine()
		}).Label("Translate from " + from + " into " + p.target.DisplayName()).Tooltip("Translate into another language (⌘L)")
		p.langChip = lc.Bounds()
		ui.Spacer(c)
		sc := p.chip(c, "service", func() {
			ui.Text(c, p.service.ShortName()).TextColor(t.Text)
		}).Label("Service: " + p.service.DisplayName()).Tooltip("Translation service (⌘1 – ⌘4)").MarginEnd(4)
		p.serviceChip = sc.Bounds()
		if p.mode != modeInput {
			icon, tip, color := iconPin, "Keep Open (⌘P)", t.TextMuted
			if p.pinned {
				icon, tip, color = iconPinFilled, "Close When Clicking Elsewhere (⌘P)", t.Accent
			}
			if p.iconButton(c, icon, tip, color).Clicked() {
				p.pinned = !p.pinned
			}
		}
		if p.iconButton(c, iconClose, "Close (Escape)", t.TextMuted).Clicked() {
			p.close()
		}
	})
}

// chip is a rounded, faintly filled button sized to its content, a little
// stronger under the mouse and while its menu is up, that opens a menu.
func (p *panel) chip(c *ui.Context, which string, content func()) ui.Element {
	t := c.Theme()
	b := ui.ButtonBase(c.Key(which)).Height(22).Padding(0, 8).Gap(4).Radius(11).FontSize(12).FontWeight(500)
	alpha := float32(0.07)
	if p.menuOpen == which {
		alpha = 0.16
	} else if b.Hovered() {
		alpha = 0.12
	}
	b.Background(t.Text.Alpha(alpha))
	b.Children(func() {
		content()
		ui.Icon(c, iconChevronDown).FontSize(10).TextColor(t.TextMuted)
	})
	b.OnClick(func() { p.showMenu(which) })
	return b
}

// iconButton draws its fill only under the mouse, as an accessory button
// does.
func (p *panel) iconButton(c *ui.Context, icon *ui.SVG, tip string, color ui.Color) ui.Element {
	t := c.Theme()
	b := ui.ButtonBase(c.Key(tip)).Size(22, 22).Center().Radius(6).Label(tip).Tooltip(tip)
	if b.Pressed() {
		b.Background(t.Text.Alpha(0.14))
	} else if b.Hovered() {
		b.Background(t.Text.Alpha(0.08))
	}
	b.Children(func() { ui.Icon(c, icon).FontSize(13).TextColor(color) })
	return b
}

func (p *panel) body(c *ui.Context) {
	t := c.Theme()
	room := float32(p.host.room())
	if room <= 0 {
		room = 800
	}
	var sel []string

	if !p.reading {
		if p.mode == modeInput {
			p.inputArea(c, room*0.3)
		} else {
			ui.Scroll(c.Key("source")).MaxHeight(sourceCap).TrackScroll(&p.sourceScroll).Children(func() {
				box := ui.Column(c).Selectable()
				box.Children(func() {
					ui.Text(c, p.source).FontSize(13).LineHeight(1.35).TextColor(t.TextMuted)
				})
				sel = selectedStrings(box.SelectedTexts())
			})
		}
	}
	// Typing takes a hint away, so what shows is decided after the field.
	hasResult := p.streaming || p.result != ""
	showResult := !p.reading && (hasResult || (p.mode == modeResult && !p.showsError))
	showNotice := p.notice != nil && !p.reading
	if showResult || showNotice {
		ui.Divider(c)
	}
	if showResult {
		p.resultView(c, room*0.5, &sel)
	}
	if showNotice {
		p.noticeView(c, *p.notice)
	}
	if p.mode == modeResult {
		p.selected = strings.Join(sel, "\n")
	}
}

func (p *panel) inputArea(c *ui.Context, cap float32) {
	t := c.Theme()
	size, color := float32(15), t.Text
	if p.sourceGrey {
		size, color = 13, t.TextMuted
	}
	lines := max(2, int(cap/(size*1.4)))
	in := ui.TextAreaBase(c.Key("input"), &p.source).Bind(&p.input).Lines(1, lines).
		FontSize(size).LineHeight(1.35).TextColor(color).
		Placeholder("Type or paste text to translate").Label("Text to translate")
	in.OnTextKey(func(k ui.TextKey) bool {
		if k.Key != ui.KeyEnter || k.Mods != 0 {
			return false // Shift+Return breaks the line
		}
		if text := strings.TrimSpace(k.Text()); text != "" && p.onTranslate != nil {
			p.onTranslate(text)
		}
		return true
	})
	if in.Changed() {
		// Edited text is the next thing to translate, not the source of the
		// result below, so it reads as primary again.
		p.sourceGrey = false
		if p.notice != nil && !p.showsError {
			p.notice = nil
		}
	}
	if start, end := in.TextSelection(); end > start {
		r := []rune(p.source)
		if end <= len(r) {
			p.selected = string(r[start:end])
		}
	} else if p.mode == modeInput {
		p.selected = ""
	}
}

func (p *panel) resultView(c *ui.Context, cap float32, sel *[]string) {
	t := c.Theme()
	// Follow the end while it streams, unless the user scrolled up.
	if p.streaming && p.resultScroll.Y >= p.resultScroll.MaxY-4 {
		p.resultScroll.Y = math.MaxFloat32
	}
	scroll := ui.Scroll(c.Key("result")).MaxHeight(cap).TrackScroll(&p.resultScroll)
	scroll.Children(func() {
		box := ui.Column(c).Selectable().Lang(string(p.target))
		if p.target.RightToLeft() {
			box.Direction(ui.RightToLeft)
		}
		box.Children(func() {
			para := ui.RichText(c).FontSize(15).LineHeight(1.4).TextColor(t.Text)
			para.Children(func() {
				ui.Text(c, p.result)
				if p.streaming {
					p.caret(c)
				}
			})
		})
		*sel = append(selectedStrings(box.SelectedTexts()), *sel...)
	})
}

// caretText is the caret: a hair space, then a bar.
const caretText = "\u200a▏"

// caret is the accent-colored bar after the last word of a streaming
// translation. It stays solid while words arrive and pulses when the
// stream goes quiet, or before the first word.
func (p *panel) caret(c *ui.Context) {
	t := c.Theme()
	quiet := p.lastChunk.IsZero() || time.Since(p.lastChunk) > 500*time.Millisecond
	alpha := float32(1)
	el := ui.Text(c, caretText).Unselectable()
	if quiet && !c.Preferences().ReduceMotion {
		phase := el.Loop("pulse", time.Second, ui.Linear)
		alpha = 0.35 + 0.65*float32(0.5+0.5*math.Cos(2*math.Pi*float64(phase)))
	} else if !quiet {
		c.After(500*time.Millisecond - time.Since(p.lastChunk))
	}
	el.TextColor(t.Accent.Alpha(alpha)).FontWeight(700)
}

func (p *panel) noticeView(c *ui.Context, n notice) {
	t := c.Theme()
	icon, tintColor, fill := iconInfo, t.Warning, t.Text.Alpha(0.06)
	if n.isError {
		icon, tintColor, fill = iconAlert, t.Danger, t.Danger.Alpha(0.12)
	}
	ui.Column(c.Key("notice")).Padding(10, 12).Gap(8).Radius(10).Background(fill).Children(func() {
		ui.Row(c).Gap(8).AlignItems(ui.Start).Children(func() {
			ui.Icon(c, icon).FontSize(15).TextColor(tintColor).Margin(1, 0, 0, 0)
			ui.Text(c, n.message).FontSize(13).LineHeight(1.35).TextColor(t.Text).Grow(1).Shrink(1).Selectable()
		})
		if n.action != nil {
			ui.Row(c).PaddingStart(23).Children(func() {
				if ui.Button(c, n.action.label).FontSize(12).Clicked() {
					n.action.run()
				}
			})
		}
	})
}

func (p *panel) footer(c *ui.Context) {
	t := c.Theme()
	showCopy := p.result != ""
	showSpeak := p.result != "" && !p.streaming
	if p.status == "" && !showCopy && !showSpeak {
		return
	}
	ui.Row(c.Key("footer")).Height(22).Gap(6).Children(func() {
		ui.Text(c, p.status).FontSize(11).FontFeatures("tnum").TextColor(t.TextMuted).SingleLine().Grow(1).Shrink(1).
			Tooltip(p.status)
		if showSpeak {
			icon, tip, color := iconSpeaker, "Speak Translation", t.TextMuted
			if p.speaking() {
				icon, tip, color = iconStop, "Stop Speaking", t.Accent
			}
			if p.iconButton(c, icon, tip, color).Clicked() {
				p.toggleSpeech()
			}
		}
		if showCopy {
			icon, color := iconCopy, t.TextMuted
			if since := time.Since(p.copiedAt); since < 1200*time.Millisecond {
				icon, color = iconCheck, t.Success
				c.After(1200*time.Millisecond - since)
			}
			if p.iconButton(c, icon, "Copy Translation (⌘C)", color).Clicked() {
				p.copyResult(c)
			}
		}
	})
}

// selectedStrings are the parts of paragraphs a selection holds.
func selectedStrings(parts []ui.SelectedText) []string {
	var out []string
	for _, part := range parts {
		r := []rune(part.Text)
		if part.Start < part.End && part.End <= len(r) {
			out = append(out, string(r[part.Start:part.End]))
		}
	}
	return out
}
