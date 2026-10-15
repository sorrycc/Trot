// Trot is a menu bar app that translates selected text, typed text and
// screenshots in a floating panel, drawn by MyGo's native UI.
package main

import (
	_ "embed"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/plugins/updater"
	"github.com/egoist/mygo/plugins/updater/native"
	"github.com/egoist/mygo/ui"

	"trot/internal/lang"
	"trot/internal/mac"
	"trot/internal/service"
	"trot/internal/settings"
	"trot/internal/shortcut"
)

//go:embed assets/tray.png
var trayPNG []byte

// trotApp is the app: its settings, the panel and the controller behind
// it, the menu bar icon, the hotkeys and the Settings window.
type trotApp struct {
	args map[string]string
	s    *settings.Settings
	p    *panel
	pw   *panelWindow
	ctl  *controller
	tray *mygo.Tray

	settingsWin  *mygo.Window
	settingsView *settingsView

	// hotKeyErr says why an action's hotkey could not be registered.
	hotKeyErr map[shortcut.Action]string
	// paused: a shortcut is being recorded, which the hotkeys would take.
	paused     bool
	lastHotKey time.Time
}

func main() {
	mygo.App.SetName("Trot")
	args := parseArgs(os.Args[1:])
	// TROT_DATA_DIR keeps the settings elsewhere, such as scripts/dev.sh's
	// Trot-dev, so a development app leaves Trot's alone.
	if dir := os.Getenv("TROT_DATA_DIR"); dir != "" {
		mygo.App.SetPath(mygo.PathUserData, dir)
	}
	// One Trot runs: opening it again shows Settings.
	if !mygo.App.RequestSingleInstanceLock() {
		return
	}
	if dir, err := mygo.App.Path(mygo.PathUserData); err == nil {
		keepCrashes(dir)
	}
	// Menu bar only: no Dock icon and no app switcher entry.
	mygo.App.SetActivationPolicy(mygo.ActivationPolicyAccessory)
	mygo.App.OnWindowAllClosed(func() {})
	// Release builds check for updates once a day and offer them in
	// MyGo's update window; development builds never check.
	mygo.Use(native.Plugin)
	// `-appearance light` or `dark` forces one, for checking both from a
	// script.
	switch args["appearance"] {
	case "dark":
		mygo.Theme.SetSource(mygo.ThemeDark)
	case "light":
		mygo.Theme.SetSource(mygo.ThemeLight)
	}
	a := &trotApp{args: args, hotKeyErr: map[shortcut.Action]string{}}
	mygo.App.OnSecondInstance(func([]string, string) { a.showSettings("") })
	mygo.App.WhenReady(a.ready)
	if err := mygo.App.Run(); err != nil {
		log.Fatal(err)
	}
}

// parseArgs reads launch arguments as user defaults took them, a name and
// a value: -translate hello -service.openAI.apiKey x.
func parseArgs(args []string) map[string]string {
	out := map[string]string{}
	for i := 0; i < len(args); i++ {
		name, ok := strings.CutPrefix(args[i], "-")
		if !ok || name == "" || strings.HasPrefix(name, "psn_") {
			continue
		}
		value := ""
		if i+1 < len(args) {
			value = args[i+1]
			i++
		}
		out[name] = value
	}
	return out
}

// overrides are the launch arguments that name settings.
func overrides(args map[string]string) map[string]string {
	out := map[string]string{}
	for k, v := range args {
		switch {
		case k == "firstLanguage", k == "secondLanguage", k == "service",
			strings.HasPrefix(k, "service."), strings.HasPrefix(k, "shortcut."):
			out[k] = v
		}
	}
	return out
}

func flag(v string) bool {
	switch strings.ToLower(v) {
	case "1", "yes", "true":
		return true
	}
	return false
}

func settingsPath() string {
	dir, err := mygo.App.Path(mygo.PathUserData)
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "settings.json")
}

func (a *trotApp) ready() {
	a.s = settings.Load(settingsPath(), overrides(a.args))
	a.s.ImportLegacy()

	a.p = newPanel(a.s)
	a.p.newSpeaker = func(onEnd func()) speaker {
		syn := mac.NewSynthesizer()
		syn.OnEnd = func() { mygo.RunOnMain(onEnd) }
		return syn
	}
	a.pw = newPanelWindow(a.p, flag(a.args["preview"]))
	a.ctl = newController(a.s, a.p)
	a.ctl.openSettings = func() { a.showSettings("Services") }

	a.setMenu()
	a.setUpTray()
	a.registerHotKeys()
	a.s.OnChange(func(key string) {
		mygo.RunOnMain(func() {
			switch {
			case strings.HasPrefix(key, "shortcut."):
				a.registerHotKeys()
				a.rebuildTray()
			case key == "service":
				a.p.service = a.s.Service()
				a.pw.win.Invalidate()
				a.rebuildTray()
			}
			if a.settingsWin != nil {
				a.settingsWin.Invalidate()
			}
		})
	})
	// The first detection loads the language model; better now than in
	// front of the first panel.
	go lang.Detect("warm up", lang.ChineseSimplified)

	// Reading the selection needs Accessibility. Asking at the first launch
	// means the first hotkey press works; after that the hotkey and
	// Settings ask again.
	if !mac.IsTrusted() && !a.s.Flag("accessibilityPrompted") {
		a.s.SetFlag("accessibilityPrompted", true)
		mac.PromptAccessibility()
	}
	// A menu bar app that opens to nothing looks like one that didn't
	// open. The first launch without a usable service shows where to set
	// one up; after that Trot starts quietly.
	if !a.s.Flag("welcomed") {
		a.s.SetFlag("welcomed", true)
		if a.s.NeedsSetup() {
			a.showSettings("Services")
		}
	}
	// For trying the app from a script: -translate "text" opens the panel
	// with that text, -input YES the input panel, -settings <pane> Settings.
	if text := a.args["translate"]; text != "" {
		a.ctl.translate(text, "", nil)
	}
	if flag(a.args["input"]) {
		a.ctl.showInput()
	}
	if pane, ok := a.args["settings"]; ok {
		a.showSettings(pane)
	}
	if out := os.Getenv("TROT_SNAPSHOT"); out != "" {
		a.snapshot(out)
	}
}

// setMenu is the menu bar for when a Trot window has the keyboard: the app
// menu, and the Edit menu, so copy and paste work in the panel and in
// Settings.
func (a *trotApp) setMenu() {
	mygo.App.SetMenu(mygo.NewMenu([]*mygo.MenuItem{
		{Label: "Trot", Submenu: []*mygo.MenuItem{
			{Label: "About Trot", Click: func(*mygo.MenuItem, *mygo.Window) { a.showSettings("About") }},
			updater.MenuItem(),
			mygo.Separator(),
			{Label: "Settings…", Accelerator: "Cmd+,", Click: func(*mygo.MenuItem, *mygo.Window) { a.showSettings("") }},
			mygo.Separator(),
			{Role: mygo.RoleHide},
			{Role: mygo.RoleQuit},
		}},
		{Role: mygo.RoleEditMenu},
		{Role: mygo.RoleWindowMenu},
	}))
}

func (a *trotApp) setUpTray() {
	tray, err := mygo.NewTray(mygo.TrayOptions{Icon: trayPNG, IconIsTemplate: true, ToolTip: "Trot"})
	if err != nil {
		log.Print("tray: ", err)
		return
	}
	a.tray = tray
	a.rebuildTray()
	mygo.App.OnWillQuit(func(*mygo.QuitEvent) { tray.Destroy() })
}

// rebuildTray sets the menu bar icon's menu: the three actions with their
// hotkeys, the service, About, Settings and Quit.
func (a *trotApp) rebuildTray() {
	if a.tray == nil {
		return
	}
	var items []*mygo.MenuItem
	for _, act := range shortcut.Actions {
		item := &mygo.MenuItem{Label: act.DisplayName(), Click: func(*mygo.MenuItem, *mygo.Window) { a.run(act) }}
		if sc, ok := a.s.Shortcut(act); ok {
			item.Accelerator = sc.Accelerator()
		}
		items = append(items, item)
	}
	var services []*mygo.MenuItem
	for _, k := range service.Kinds {
		services = append(services, &mygo.MenuItem{Label: k.DisplayName(), Type: mygo.MenuItemRadio, Checked: k == a.s.Service(),
			Click: func(*mygo.MenuItem, *mygo.Window) { a.s.SetService(k) }})
	}
	items = append(items,
		mygo.Separator(),
		&mygo.MenuItem{Label: "Service: " + a.s.Service().ShortName(), Submenu: services},
		mygo.Separator(),
		&mygo.MenuItem{Label: "About Trot", Click: func(*mygo.MenuItem, *mygo.Window) { a.showSettings("About") }},
		&mygo.MenuItem{Label: "Settings…", Accelerator: "Cmd+,", Click: func(*mygo.MenuItem, *mygo.Window) { a.showSettings("") }},
		&mygo.MenuItem{Label: "Check for Updates…", Click: func(*mygo.MenuItem, *mygo.Window) { updater.CheckForUpdates() }},
		mygo.Separator(),
		&mygo.MenuItem{Label: "Quit Trot", Accelerator: "Cmd+Q", Click: func(*mygo.MenuItem, *mygo.Window) { mygo.App.Quit() }},
	)
	a.tray.SetMenu(mygo.NewMenu(items))
}

// registerHotKeys registers the actions' global shortcuts anew. Carbon
// hotkeys need no Accessibility permission and fire whichever app is in
// front.
func (a *trotApp) registerHotKeys() {
	mygo.GlobalShortcut.UnregisterAll()
	a.hotKeyErr = map[shortcut.Action]string{}
	if a.paused {
		return
	}
	for _, act := range shortcut.Actions {
		sc, ok := a.s.Shortcut(act)
		if !ok {
			continue
		}
		if err := mygo.GlobalShortcut.Register(sc.Accelerator(), func() { a.hotKey(act) }); err != nil {
			log.Printf("hotkey %s: %v", sc.Accelerator(), err)
			a.hotKeyErr[act] = "Another app uses " + sc.Display() + ", or macOS keeps it."
		}
	}
}

// pauseHotKeys lets a shortcut being recorded reach Settings.
func (a *trotApp) pauseHotKeys(on bool) {
	a.paused = on
	a.registerHotKeys()
}

// hotKey runs an action for its hotkey. A held key repeats the hotkey;
// one translation per press is enough.
func (a *trotApp) hotKey(act shortcut.Action) {
	if time.Since(a.lastHotKey) < 300*time.Millisecond {
		return
	}
	a.lastHotKey = time.Now()
	a.run(act)
}

func (a *trotApp) run(act shortcut.Action) {
	switch act {
	case shortcut.TranslateSelection:
		a.ctl.translateSelection()
	case shortcut.TranslateInput:
		a.ctl.showInput()
	case shortcut.TranslateScreenshot:
		a.ctl.translateScreenshot()
	}
}

// showSettings brings Settings to the front, on a pane when one is named.
func (a *trotApp) showSettings(pane string) {
	if a.settingsWin == nil {
		v := newSettingsView(a)
		a.settingsView = v
		win := mygo.NewWindow(mygo.WindowOptions{
			Title:           "Trot Settings",
			Width:           settingsWidth,
			Height:          420,
			UseContentSize:  true,
			DisableResize:   true,
			DisableMaximize: true,
			Hidden:          true,
			Content:         ui.View(v.view),
		})
		v.resize = func(h int) {
			// Grow and shrink with the top edge still.
			b := win.Bounds()
			_, oldH := win.ContentSize()
			win.SetContentSize(settingsWidth, h)
			nb := win.Bounds()
			if nb.Y != b.Y && oldH > 0 {
				win.SetPosition(nb.X, b.Y)
			}
		}
		win.OnClosed(func() {
			if v.testCancel != nil {
				v.testCancel()
			}
			if a.paused {
				a.pauseHotKeys(false)
			}
			a.settingsWin, a.settingsView = nil, nil
		})
		a.settingsWin = win
	}
	if pane != "" {
		a.settingsView.showPane(pane)
	}
	mygo.App.Focus()
	a.settingsWin.Show()
	a.settingsWin.Focus()
	a.settingsWin.Invalidate()
}
