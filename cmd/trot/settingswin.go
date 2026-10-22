package main

import (
	"context"
	_ "embed"
	"errors"
	"math"
	"strings"
	"sync"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/plugins/updater"
	"github.com/egoist/mygo/ui"

	"trot/internal/cloudsync"
	"trot/internal/lang"
	"trot/internal/mac"
	"trot/internal/service"
	"trot/internal/shortcut"
)

//go:embed assets/about.png
var aboutPNG []byte

// aboutIcon is decoded the first time About shows, not at every launch.
var aboutIcon = sync.OnceValue(func() *ui.Bitmap {
	b, _ := ui.DecodeBitmap(aboutPNG)
	return b
})

// Facts about the app, for About and the links in Settings.
const (
	homepage  = "https://github.com/sorrycc/trot"
	issues    = "https://github.com/sorrycc/trot/issues"
	license   = "https://github.com/sorrycc/trot/blob/main/LICENSE"
	copyright = "© 2026 chencheng"
)

var panes = []string{"General", "Services", "Shortcuts", "About"}

// paneIcons are the icons of the panes' tabs.
var paneIcons = []*ui.SVG{iconGeneral, iconServices, iconKeyboard, iconInfo}

const settingsWidth = 540

// settingsView is the Settings window's content: one pane at a time, each
// a form of rows, a title on the left and its control on the right, with
// notes under a row when there is something to say about its value.
// Changes save as they are made.
type settingsView struct {
	a    *trotApp
	pane int

	// The service whose fields show, and the fields as typed.
	shown                  service.Kind
	baseURL, apiKey, model string

	testing             bool
	testResult, testErr string
	testCancel          context.CancelFunc

	recorders map[shortcut.Action]*recorder
	loginErr  string
	fitted    int
	resize    func(height int)
	// paneShown and testShown are what the entrances of the pane and of
	// a test's check last eased in, and tabPopped the pane whose tab's
	// icon last popped.
	paneShown, testShown, tabPopped any
	// system is what General shows of the system, read at most once a
	// second rather than in every frame.
	system    systemState
	checkedAt time.Time
}

// systemState is what macOS says of Trot: the permissions it has and
// whether it opens at login.
type systemState struct {
	trusted, recording, atLogin bool
}

// systemNow reads the system's state again once a second has passed:
// asking macOS takes a trip to the main thread and the permission
// databases, which hovering a control in General need not repeat.
func (v *settingsView) systemNow() systemState {
	if time.Since(v.checkedAt) >= time.Second {
		v.checkedAt = time.Now()
		v.system = systemState{trusted: mac.IsTrusted(), recording: mac.ScreenCaptureAllowed(), atLogin: mygo.App.OpenAtLogin()}
	}
	return v.system
}

func newSettingsView(a *trotApp) *settingsView {
	v := &settingsView{a: a, recorders: map[shortcut.Action]*recorder{}}
	for _, act := range shortcut.Actions {
		v.recorders[act] = &recorder{}
	}
	return v
}

func (v *settingsView) showPane(name string) {
	for i, p := range panes {
		if strings.EqualFold(p, name) {
			v.pane = i
		}
	}
}

func (v *settingsView) view(c *ui.Context) {
	card := ui.Column(c.Key("settings")).Width(settingsWidth).Shrink(0)
	card.Children(func() {
		v.tabs(c)
		pane := ui.Column(c.Key(panes[v.pane])).Padding(18, 28, 24).Gap(16)
		// A pane picked rises in as the window takes its height.
		entrance(pane, &v.paneShown, v.pane, 6)
		pane.Children(func() {
			switch v.pane {
			case 0:
				v.general(c)
			case 1:
				v.services(c)
			case 2:
				v.shortcuts(c)
			case 3:
				v.about(c)
			}
		})
	})
	if h := int(math.Ceil(float64(card.LayoutBounds().H))); h > 0 && h != v.fitted && v.resize != nil {
		v.fitted = h
		v.resize(h)
	}
}

// tabs are the panes as a toolbar of icons over their names, as macOS
// Settings windows have, over a hairline. The tab picked takes the
// accent and a soft fill, which fade from one tab to the next.
func (v *settingsView) tabs(c *ui.Context) {
	t := c.Theme()
	ui.Column(c).Children(func() {
		ui.Row(c).Justify(ui.Center).Padding(10, 20, 8).Children(func() {
			seg := ui.SegmentedBase(c, &v.pane, len(panes))
			seg.Track.Gap(2).Label("Settings pane").Children(func() {
				for i, name := range panes {
					tab := seg.Segment(i).Width(76).Height(50).Radius(8).Gap(3).Column().Label(name)
					on := i == v.pane
					fill, color := t.Text.Alpha(0), t.TextMuted
					switch {
					case on:
						fill, color = t.Text.Alpha(0.07), t.Accent
					case tab.Pressed():
						fill = t.Text.Alpha(0.09)
					case tab.Hovered():
						fill = t.Text.Alpha(0.045)
					}
					tab.Background(tab.AnimateColor("fill", fill, tabAnim))
					pressScale(tab, tab.Pressed())
					tab.Children(func() {
						ic := ui.Icon(c.Key("icon"), paneIcons[i]).FontSize(20)
						ic.TextColor(ic.AnimateColor("color", color, tabAnim))
						// The icon of the tab picked pops, as a tap on it.
						if on {
							pop(ic, &v.tabPopped, v.pane)
						}
						text := t.Text
						if on {
							text = t.Accent
						}
						label := ui.Text(c, name).FontSize(11).FontWeight(500).SingleLine()
						label.TextColor(label.AnimateColor("color", text, tabAnim))
					})
				}
			})
		})
		ui.Box(c).Height(1).AlignSelf(ui.Stretch).Background(t.Text.Alpha(0.08))
	})
}

// labelColumn sizes a form's column of labels to the widest label of
// every pane, so the labels and controls stay in place as the panes
// change: it lays out each such label in a row of no height that draws
// nothing. It goes first in the form.
func labelColumn(c *ui.Context) {
	gap := c.Theme().Space(3)
	widest := []string{"Second language", "Open Trot at login", "Screen Recording", "Test translation"}
	for _, act := range shortcut.Actions {
		widest = append(widest, strings.TrimSuffix(act.DisplayName(), "…"))
	}
	for i, label := range widest {
		ui.Field(c.Key(i), label, func() {}).Height(0).Margin(0, 0, -gap, 0).Invisible()
	}
}

// note is a description under a row.
func note(c *ui.Context, text string) {
	ui.Text(c, text).FontSize(11).LineHeight(1.35).TextColor(c.Theme().TextMuted)
}

func (v *settingsView) general(c *ui.Context) {
	s := v.a.s
	names := make([]string, len(lang.All))
	for i, l := range lang.All {
		names[i] = l.DisplayName()
	}
	byName := func(name string) lang.Language {
		for _, l := range lang.All {
			if l.DisplayName() == name {
				return l
			}
		}
		return ""
	}
	first, second := s.FirstLanguage().DisplayName(), s.SecondLanguage().DisplayName()
	sys := v.systemNow()
	ui.Form(c, func() {
		labelColumn(c)
		ui.Field(c, "First language", func() {
			if ui.Select(c, &first, names).Changed() {
				s.SetLanguages(byName(first), s.SecondLanguage())
			}
		}).Description("Text in any other language is translated into this one.")
		ui.Field(c, "Second language", func() {
			if ui.Select(c, &second, names).Changed() {
				s.SetLanguages(s.FirstLanguage(), byName(second))
			}
		}).Description("Text already in the first language is translated into this one.")
		section(c)
		atLogin := sys.atLogin
		ui.Field(c, "Open Trot at login", func() {
			if ui.Switch(c, &atLogin).Changed() {
				v.loginErr = ""
				if err := mygo.App.SetOpenAtLogin(atLogin); err != nil {
					v.loginErr = err.Error()
				}
				// Read again in the next frame, not a second late.
				v.checkedAt = time.Time{}
			}
		}).Error(v.loginErr)
		ui.Field(c, "Accessibility", func() {
			permission(c, sys.trusted, mac.AccessibilitySettingsURL)
		}).Description("Reading the selection in other apps needs it.")
		ui.Field(c, "Screen Recording", func() {
			permission(c, sys.recording, mac.ScreenCaptureSettingsURL)
		}).Description("Translating screenshots needs it. macOS reports a grant only after Trot is opened again.")
		section(c)
		crashes := s.SendsCrashReports()
		ui.Field(c, "Crash reports", func() {
			// The text beside the switch gives the row a baseline, which
			// the label lines up with.
			ui.Row(c).Gap(10).AlignItems(ui.Center).Children(func() {
				if ui.Switch(c, &crashes).Label("Send crash reports to Mon").Changed() {
					s.SetSendsCrashReports(crashes)
				}
				ui.Text(c, "Send to Mon").FontSize(13)
			})
		}).Description("A crash's report goes at the next launch, anonymously, with your home folder taken out.")
	})
	// Permissions change in System Settings, not here.
	c.After(time.Second)
}

// section is a hairline between groups of a form's rows.
func section(c *ui.Context) {
	ui.Box(c).Height(1).AlignSelf(ui.Stretch).Margin(2, 0).Background(c.Theme().Text.Alpha(0.07))
}

func permission(c *ui.Context, granted bool, url string) {
	t := c.Theme()
	ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
		if granted {
			ui.Icon(c, iconCheck).FontSize(14).TextColor(t.Success)
			ui.Text(c, "Granted").FontSize(13)
			return
		}
		ui.Icon(c, iconAlert).FontSize(14).TextColor(t.Warning)
		ui.Text(c, "Not granted").FontSize(13).TextColor(t.TextMuted).MarginEnd(2)
		if ui.Button(c, "Open System Settings…").FontSize(12).Clicked() {
			mygo.Shell.OpenExternal(url)
		}
	})
}

// loadFields reads the fields of the active service, as it changes.
func (v *settingsView) loadFields() {
	s := v.a.s
	k := s.Service()
	if k == v.shown && v.shown != "" {
		return
	}
	v.shown = k
	v.baseURL, v.apiKey, v.model = s.BaseURL(k), s.APIKey(k), s.Model(k)
	v.testResult, v.testErr = "", ""
}

func (v *settingsView) services(c *ui.Context) {
	s := v.a.s
	v.loadFields()
	k := v.shown
	names := make([]string, len(service.Kinds))
	for i, kind := range service.Kinds {
		names[i] = kind.DisplayName()
	}
	chosen := k.DisplayName()
	ui.Form(c, func() {
		labelColumn(c)
		ui.Field(c, "Service", func() {
			if ui.Select(c, &chosen, names).Changed() {
				for _, kind := range service.Kinds {
					if kind.DisplayName() == chosen {
						s.SetService(kind)
					}
				}
				v.loadFields()
			}
		}).Description(serviceNote(k))
		if k.SignsIn() || v.a.account.signin != nil {
			v.accountField(c)
		}
		if k.HasBaseURL() {
			ui.Field(c, "Base URL", func() {
				if ui.TextInput(c.Key(string(k)+"url"), &v.baseURL).Placeholder(k.DefaultBaseURL()).Changed() {
					s.SetBaseURL(k, v.baseURL)
				}
			}).Description("Requests go to " + endpoint(k, s.ActiveBaseURL(k)) + ". Point it at DeepSeek, Qwen, Ollama or a proxy.")
		}
		if k.NeedsKey() {
			ui.Field(c, "API key", func() {
				ui.Column(c).Gap(6).Children(func() {
					if ui.TextInput(c.Key(string(k)+"key"), &v.apiKey).Password().Placeholder("Required").Changed() {
						s.SetAPIKey(k, v.apiKey)
					}
					ui.Link(c, "Get an API key", k.KeyPage()).FontSize(12)
				})
			}).Description(keyNote(k))
		}
		if k.HasModel() {
			f := ui.Field(c, "Model", func() {
				if ui.TextInput(c.Key(string(k)+"model"), &v.model).Placeholder(k.DefaultModel()).Changed() {
					s.SetModel(k, v.model)
				}
			})
			if k.SignsIn() {
				f.Description("The models your account can use are listed at " + k.DefaultBaseURL() + "/v1/models.")
			}
		}
		ui.Field(c, "Test translation", func() {
			ui.Row(c).Gap(10).Children(func() {
				if v.testing {
					ui.Spinner(c).Size(16, 16)
					ui.Text(c, "Translating…").FontSize(13).TextColor(c.Theme().TextMuted)
					return
				}
				if ui.Button(c, "Test").Clicked() {
					v.test()
				}
				if v.testResult != "" {
					ok := ui.Row(c.Key("works")).Gap(6).AlignItems(ui.Center)
					entrance(ok, &v.testShown, v.testResult, 4)
					ok.Children(func() {
						ui.Icon(c, iconCheck).FontSize(14).TextColor(c.Theme().Success)
						ui.Text(c, "Works").FontSize(13)
					})
				}
			})
		}).Description(v.testNote()).Error(v.testErr)
	})
}

// accountField is the Mon account: Sign In while signed out, the code to
// approve while signing in, and the person, with settings sync and Sign
// Out, once signed in.
func (v *settingsView) accountField(c *ui.Context) {
	acct := v.a.account
	t := c.Theme()
	note := "Sign in with GitHub or Google. No API key needed, and your settings sync between your Macs."
	f := ui.Field(c, "Mon account", func() {
		ui.Column(c).Gap(6).Children(func() {
			switch si := acct.signin; {
			case si != nil:
				ui.Row(c).Gap(10).Children(func() {
					ui.Spinner(c).Size(16, 16)
					if si.code == "" {
						ui.Text(c, "Starting…").FontSize(13).TextColor(t.TextMuted)
					} else {
						ui.Text(c, si.code).FontSize(15).Bold().Selectable()
					}
					if ui.Button(c, "Cancel").FontSize(12).Clicked() {
						acct.cancelSignIn()
					}
				})
				if si.url != "" {
					ui.Link(c, "Open the Sign-In Page Again", si.url).FontSize(12)
				}
				note = "Check that the page that opened in your browser shows this code, then approve it."
			case acct.signedIn():
				ui.Row(c).Gap(10).Children(func() {
					ui.Text(c, acct.name()).FontSize(13)
					if ui.Button(c, "Sign Out").FontSize(12).Clicked() {
						acct.signOut()
					}
				})
				ui.Row(c).Gap(14).Children(func() {
					sync := ui.Button(c, "Sync Now").FontSize(12).Disabled(acct.busy > 0)
					if sync.Clicked() {
						acct.sync(cloudsync.Ask, true)
					}
					ui.Link(c, "Manage Account", service.MonURL()+"/account").FontSize(12)
				})
				note = acct.syncStatus()
				if email := acct.email(); email != "" {
					note = email + ". " + note
				}
				// The time of the last sync reads as words that age.
				c.After(30 * time.Second)
			default:
				ui.Row(c).Children(func() {
					if ui.Button(c, "Sign In…").Clicked() {
						acct.signIn()
					}
				})
			}
		})
	}).Description(note)
	if acct.signInErr != "" && acct.signin == nil && !acct.signedIn() {
		f.Error(acct.signInErr)
	}
}

func (v *settingsView) testNote() string {
	if v.testResult != "" {
		return "“" + v.testResult + "”"
	}
	return "Translates a sentence with these settings."
}

func serviceNote(k service.Kind) string {
	switch k {
	case service.Mon:
		return "Mon's AI gateway, with your Mon account. A free account translates 500,000 tokens a day."
	case service.OpenAI:
		return "Any chat completions API: OpenAI, DeepSeek, Qwen, Ollama and others."
	case service.Claude:
		return "Anthropic's Messages API."
	case service.DeepL:
		return "Keys ending in :fx use the free API."
	}
	return "Google's web endpoint. No key, but unofficial, so it can stop working."
}

func keyNote(k service.Kind) string {
	return "Kept in Trot's settings file, never sent anywhere but " + k.DisplayName() + "."
}

// endpoint is the URL requests of k go to.
func endpoint(k service.Kind, base string) string {
	if k == service.Claude {
		return base + "/v1/messages"
	}
	return base + "/chat/completions"
}

// test translates a sentence from English into wherever English goes,
// with the settings as they are.
func (v *settingsView) test() {
	s := v.a.s
	k := s.Service()
	cfg := s.Config(k)
	target := s.Target(lang.English)
	v.testing, v.testResult, v.testErr = true, "", ""
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	v.testCancel = cancel
	win := v.a.settingsWin
	go func() {
		defer cancel()
		var b strings.Builder
		err := service.Translate(ctx, k, cfg, "The quick brown fox jumps over the lazy dog.", lang.English, target,
			func(ch service.Chunk) { b.WriteString(ch.Text) })
		// Closing Settings cancels the test; its window takes no updates.
		if ctx.Err() == context.Canceled {
			return
		}
		win.Update(func() {
			v.testing = false
			if errors.Is(err, service.ErrSignedOut) {
				v.a.account.sessionEnded()
			}
			switch {
			case err != nil:
				v.testErr = service.Describe(err)
			case strings.TrimSpace(b.String()) == "":
				v.testErr = k.DisplayName() + " sent back an empty translation."
			default:
				v.testResult = strings.TrimSpace(b.String())
			}
		})
	}()
}

func (v *settingsView) shortcuts(c *ui.Context) {
	s := v.a.s
	t := c.Theme()
	ui.Form(c, func() {
		labelColumn(c)
		for _, act := range shortcut.Actions {
			name := strings.TrimSuffix(act.DisplayName(), "…")
			current, ok := s.Shortcut(act)
			f := ui.Field(c, name, func() {
				ui.Row(c).Gap(6).Children(func() {
					recorderButton(c.Key(string(act)), v.recorders[act], name, current, ok,
						func(sc *shortcut.Shortcut) { s.SetShortcut(act, sc) },
						v.a.pauseHotKeys)
					reset := ui.ButtonBase(c.Key(string(act)+"reset")).Size(24, 24).Center().Radius(6).
						Label("Use Default Shortcut").Tooltip("Use the default, " + act.Default().Display()).
						Disabled(!s.ShortcutIsCustom(act))
					fill := t.SurfaceHover.Alpha(0)
					if reset.Hovered() {
						fill = t.SurfaceHover
					}
					reset.Background(reset.AnimateColor("fill", fill, hoverAnim))
					pressScale(reset, reset.Pressed())
					color := t.TextMuted
					if !s.ShortcutIsCustom(act) {
						color = color.Alpha(0.4)
					}
					reset.Children(func() {
						ic := ui.Icon(c, iconReset).FontSize(13)
						ic.TextColor(ic.AnimateColor("color", color, hoverAnim))
					})
					if reset.Clicked() {
						s.ResetShortcut(act)
					}
				})
			})
			if err := v.a.hotKeyErr[act]; err != "" {
				f.Error(err)
			}
		}
	})
	note(c, "Click a shortcut, then press a combination with ⌘, ⌥ or ⌃. Delete clears it. "+
		"The shortcuts work in every app, without the Accessibility permission.")
}

func (v *settingsView) about(c *ui.Context) {
	t := c.Theme()
	ui.Column(c).AlignItems(ui.Center).Gap(8).Padding(6, 0, 4).Children(func() {
		if icon := aboutIcon(); icon != nil {
			// The icon lifts a little under the mouse.
			img := ui.Image(c.Key("icon"), icon).Size(96, 96)
			lift := float32(1)
			if img.Hovered() {
				lift = 1.05
			}
			if k := img.AnimateTo("lift", lift, pressAnim); k != 1 {
				img.Scale(k, k)
			}
		}
		ui.Text(c, "Trot").FontSize(20).Bold()
		version := "Development build"
		if v := mygo.App.Version(); v != "" {
			version = "Version " + v
		}
		ui.Text(c, version).FontSize(12).TextColor(t.TextMuted).Selectable()
		ui.Text(c, "Translates selected text, typed text and screenshots in a floating panel.").
			FontSize(13).TextAlign(ui.Center).MaxWidth(360).Margin(6, 0, 0)
		if ui.Button(c, "Check for Updates…").FontSize(12).Margin(6, 0, 0).Clicked() {
			updater.CheckForUpdates()
		}
		ui.Row(c).Gap(16).Margin(6, 0, 0).Children(func() {
			ui.Link(c, "Homepage", homepage).FontSize(12)
			ui.Link(c, "Report an Issue", issues).FontSize(12)
			ui.Link(c, "License", license).FontSize(12)
		})
		ui.Text(c, copyright).FontSize(11).TextColor(t.TextMuted).Margin(6, 0, 0)
	})
}
