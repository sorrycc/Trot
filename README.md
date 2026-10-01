<p align="center">
  <img src="app/Resources/Trot-1024.png" width="128" height="128" alt="Trot icon">
</p>

# Trot

A small macOS translation app in the spirit of [Bob](https://github.com/ripperhe/Bob), kept simple: a menu bar icon, three hotkeys and one floating panel. Native Swift and AppKit, no web views, so the panel is on screen before you've let go of the keys.

<p align="center">
  <img src="docs/images/panel-dark.png" width="486" alt="The Trot panel with an English sentence and its Chinese translation">
</p>

## Features

- **Translate the selection.** Press ⌥D with text selected in any app. The translation streams into a glass panel at the mouse, which grows with the text.
- **Translate what you type.** ⌥A opens the same panel with an editable field. Return translates, Shift+Return adds a line.
- **Translate a screenshot.** ⌥S draws the system crosshair over a region, reads the text with Vision, and translates it.
- **Two-language rule.** Text in any language goes into your first language; text already in it goes into your second. Pick another target from the chip in the panel, or with ⌘L.
- **Services.** Any OpenAI-compatible chat API (OpenAI, DeepSeek, Qwen, Ollama), Claude, DeepL, or Google's unofficial endpoint. Switch in the panel (⌘1 to ⌘4), from the menu bar icon, or in Settings.
- **Hotkeys you can change**, launch at login, a speaker button that reads the translation aloud, and a copy button that copies the whole translation. ⌘P pins the panel.
- **Fails politely.** An error takes the place of the translation and says what to do: a missing key or a wrong base URL comes with an Open Settings button, a network error with Retry, and Return presses it.
- **Quick.** The panel is built at launch, long selections are laid out only as far as shown, and the connection to the service opens while the selection is read.

## Requirements

- macOS 26 or later
- The Swift toolchain from the Xcode Command Line Tools, to build and test

## Build and run

```sh
scripts/bundle.sh        # release build; pass `debug` for a debug build
open build/Trot.app
```

The script builds the Swift package and assembles an ad-hoc signed `build/Trot.app`. Trot lives in the menu bar; there is no Dock icon.

```sh
scripts/test.sh          # unit tests (Swift Testing)
scripts/release.sh       # tests, release build, build/Trot-<version>.zip
scripts/mock-service.py  # a fake streaming service, for trying the panel without a key
```

At the first launch macOS asks for Accessibility access, which reading the selection in other apps needs. Screen Recording is asked for the first time you translate a screenshot. Then open Settings from the menu bar icon, pick a service, and enter its key.

## Project layout

| Path | Description |
|---|---|
| `app/` | SwiftPM package with the AppKit app. No Xcode project is required. |
| `app/Sources/Trot/Services/` | One file per translation service. |
| `app/Tests/TrotTests/` | Unit tests for detection, shortcuts, OCR text joining and the HTTP helpers. |
| `scripts/bundle.sh` | Builds and assembles `build/Trot.app`. |
| `scripts/test.sh` | Runs the tests, with the Command Line Tools or Xcode. |
| `scripts/release.sh` | Tests, builds and zips a release. |
| `scripts/mock-service.py` | An OpenAI-compatible fake that streams, fails or answers in one piece. |
| `scripts/make-icon.swift` | Cuts the app icon and `.icns` out of `app/Resources/Trot-artwork.png`. |
| `.github/workflows/ci.yml` | Builds and tests on every push. |

## Documentation

| Guide | Covers |
|---|---|
| [Using Trot](docs/using.md) | The panel, hotkeys, languages, screenshots |
| [Settings and data](docs/settings-and-data.md) | Settings, services, where data lives, launch arguments |

## License

[MIT](LICENSE)
