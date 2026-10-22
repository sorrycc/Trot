# Development

Trot is a Go program with a native UI drawn by [MyGo](https://github.com/egoist/mygo). It needs Go 1.27 or later and nothing else: no Xcode project and no cgo. The macOS frameworks MyGo has no API for (Accessibility, synthesized keys, the pasteboard, Vision, speech and NaturalLanguage) are called through purego in `internal/mac`.

## Scripts

```sh
go tool mygo build            # build/darwin-arm64/Trot.app and a .dmg, signed ad hoc
scripts/dev.sh                # Trot from source with live reload, with its own settings
go test ./...                 # unit and headless UI tests
go test -short ./...          # the same, leaving the clipboard alone
scripts/mock-service.py       # a fake streaming service, for trying the panel without a key
scripts/bump.sh patch         # release a new version, see Releasing
```

`scripts/dev.sh` builds Trot as a bare binary in `.mygo/dev`, runs it, and builds and restarts it when a Go file, an asset or `mygo.json` changes; a build that fails keeps the last one running. It passes its arguments to the app, as `scripts/dev.sh -translate hello`, and keeps its settings in `~/Library/Application Support/Trot-dev`, so the everyday Trot's stay as they are. Quit the everyday Trot first, or both take the hotkeys. It runs a bare binary rather than `go tool mygo dev`'s "Trot Dev" bundle because macOS 26 keeps that bundle's menu bar icon hidden, even with "Allow in the Menu Bar" on.

## Trying the panel without a key

`scripts/mock-service.py` serves a fake OpenAI-compatible API on `http://127.0.0.1:48765`. Any setting can be given as a launch argument, which overrides the saved one for that run only:

```sh
open build/darwin-arm64/Trot.app --args -service openAI -service.openAI.baseURL http://127.0.0.1:48765/v1 -service.openAI.apiKey x -translate hello
```

The path picks the behaviour: `/v1` streams a translation one character at a time, `/slow` does so slowly, `/fail` answers with an error, `/plain` ignores `stream` and answers with one message, as some gateways do, `/empty` streams nothing, `/rtl` answers in Arabic, `/long` with several screens of text, `/length` stops with `finish_reason: length`, as a cut-off reply does, and `/think` sends reasoning first and then a short reply in one burst, as DeepSeek's thinking models do.

## Trying Mon on localhost

`TROT_MON_URL` points the Mon service, the sign-in, settings sync and crash reports at another Mon, such as one run from the Mon repository with `MON_DEV_LOGIN=1`, whose sign-in page has a one-click test user. Crash reports, which only release builds send, are sent with it set too:

```sh
TROT_MON_URL=http://localhost:8080 scripts/dev.sh
```

## Looking at the real window

`TROT_SNAPSHOT=out.png` captures the panel three seconds after launch and quits, or Settings with `TROT_SNAPSHOT_WINDOW=settings`; `TROT_DATA_DIR` keeps the settings of such a run apart. The window's number goes to `out.png.id`, for `screencapture -l`, which shows the material behind the panel too, and its bounds to `out.png.bounds`:

```sh
TROT_DATA_DIR=/tmp/trot TROT_SNAPSHOT=/tmp/panel.png TROT_SNAPSHOT_KEEP=1 \
  build/darwin-arm64/Trot.app/Contents/MacOS/Trot -preview YES -translate hello &
sleep 4; screencapture -o -l$(cat /tmp/panel.png.id) docs/images/panel.png
```

## Tests

`go test ./...` covers language detection, the two-language rule and the swap, shortcut parsing, display and the migration of old ones, settings and the import of the old user defaults, the joining of screenshot lines into paragraphs, the HTTP helpers, base URL tidying, error messages, the service language codes, the services against a test server, Mon's client, the settings sync merge against a fake account, crash reports, the selection reader against a fake system, and the panel and the controller, headless with MyGo's tester. The tests of `internal/mac` call the real frameworks: Vision reads text MyGo drew, and one test writes the clipboard and puts it back, which `-short` skips.

`TROT_SHOTS=<dir> go test -run TestShots ./cmd/trot` draws the panel's states, light and dark, into `<dir>`.

## Continuous integration

`.github/workflows/ci.yml` runs on every push to `main` or `master` and on pull requests. It vets and tests the code, builds the app, verifies its signature and uploads `Trot.app` as a build artifact.

## Releasing

Write the release notes under `## Unreleased` in `CHANGELOG.md` and commit them, then:

```sh
scripts/bump.sh patch    # or minor, major, or a version such as 0.5.0
```

It first checks that the repository has every secret the Release workflow uses. Then it sets the version in `mygo.json`, renames `## Unreleased` to `## <version>` in `CHANGELOG.md`, commits and tags `v<version>`, and after asking pushes `main` and the tag. The [Release workflow](../.github/workflows/release.yml) then builds the app for Apple silicon and Intel, uploads the disk images and the signed updates, and publishes the release. Installed apps check for it once a day, and from **Check for Updates…**; the update window shows the version's section of the changelog.

The workflow needs these repository secrets:

| Secret | What |
|---|---|
| `MYGO_UPDATER_PRIVATE_KEY` | `mygo-update.key` from `go tool mygo keygen`, whose public key is in `mygo.json`. Required |
| `MACOS_CERTIFICATE` | the Developer ID Application certificate and its key, as a base64 `.p12`. Required: an update signed ad hoc would lose the app's Accessibility and Screen Recording access |
| `MACOS_CERTIFICATE_PASSWORD` | the password of the `.p12` |
| `APPLE_ID`, `APPLE_TEAM_ID` | the Apple ID of the developer account, and its team ID |
| `APPLE_APP_PASSWORD` | an app-specific password of the Apple ID, from account.apple.com |

All of them are required. Local builds stay signed ad hoc; only the workflow signs with the Developer ID and notarizes.

## Project layout

| Path | Description |
|---|---|
| `cmd/trot/` | The app: `main.go` (the menu bar icon, the hotkeys, the menus and launch arguments), `controller.go` (selection, input and screenshot to a translation), `panel.go` and `panelwin.go` (the floating panel and its window), `settingswin.go` and `recorder.go` (Settings), `account.go` (the Mon sign-in and settings sync), `crashlog.go` and `crashreport.go` (crash logs and their reports). |
| `internal/mon/` | Mon's Go client, a copy of the private `github.com/sorrycc/mon/client`: the device sign-in, the settings document and crash reports. |
| `internal/cloudsync/` | Settings sync: the merge with the account's settings, ported from Mayoi. |
| `internal/mac/` | The macOS frameworks through purego: Accessibility, ⌘C, the pasteboard, Vision, speech, NaturalLanguage and the panel's window. |
| `internal/selection/` | Reads the selection of the frontmost app, through Accessibility or a copy. |
| `internal/service/` | One function per translation service, and the HTTP and server-sent event helpers. |
| `internal/lang/` | The languages, their detection and the two-language rule. |
| `internal/ocr/` | The screenshot crosshair and joining its lines into paragraphs. |
| `internal/settings/` | `settings.json`, which of its settings sync, and the import of the old user defaults. |
| `internal/shortcut/` | Hotkey combinations as accelerators. |
| `resources/icon.png` | The app icon, which `mygo build` makes the `.icns` of. |
| `art/` | The artwork the icons were cut from. |
| `mygo.json` | The app's name, identifier, version, `Info.plist` keys and update key. |
| `scripts/` | Development, mock service and release scripts. |
| `.github/workflows/` | CI on every push, and the release on every tag. |
