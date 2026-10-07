# Development

Trot is a Swift package with an AppKit app. You don't need an Xcode project; the Command Line Tools are enough.

## Scripts

```sh
scripts/bundle.sh        # release build into build/Trot.app; pass `debug` for a debug build
scripts/test.sh          # unit tests (Swift Testing)
scripts/release.sh       # tests, release build, build/Trot-<version>.zip
scripts/mock-service.py  # a fake streaming service, for trying the panel without a key
```

`bundle.sh` signs the app ad hoc.

## Trying the panel without a key

`scripts/mock-service.py` serves a fake OpenAI-compatible API on `http://127.0.0.1:48765`. Any setting can be given as a launch argument, which overrides the saved one for that run only:

```sh
open build/Trot.app --args -service openAI -service.openAI.baseURL http://127.0.0.1:48765/v1 -service.openAI.apiKey x -translate hello
```

The path picks the behaviour: `/v1` streams a translation one character at a time, `/slow` does so slowly, `/fail` answers with an error, `/plain` ignores `stream` and answers with one message, as some gateways do, `/empty` streams nothing, `/rtl` answers in Arabic, `/long` with several screens of text, and `/length` stops with `finish_reason: length`, as a cut-off reply does.

## Tests

`scripts/test.sh` runs the unit tests with Swift Testing. They cover language detection, the two-language rule and the swap, shortcut parsing and display, the joining of screenshot lines into paragraphs, the HTTP helpers, base URL tidying, error messages, the service language codes, which button an error gets, and the Settings form's hairlines and sizing. The script adds the framework paths the Command Line Tools need; with Xcode installed, `swift test --package-path app` works too.

## Continuous integration

`.github/workflows/ci.yml` runs on every push to `main` or `master` and on pull requests. It runs the tests, builds a release bundle, verifies its signature and uploads `Trot.app` as a build artifact.

## Project layout

| Path | Description |
|---|---|
| `app/` | SwiftPM package with the AppKit app. |
| `app/Sources/Trot/Services/` | One file per translation service. |
| `app/Sources/Trot/SettingsWindow/` | The Settings window: the grouped form and one file per pane. |
| `app/Tests/TrotTests/` | Unit tests for detection, shortcuts, OCR text joining, the HTTP helpers and the Settings form. |
| `scripts/bundle.sh` | Builds and assembles `build/Trot.app`. |
| `scripts/test.sh` | Runs the tests, with the Command Line Tools or Xcode. |
| `scripts/release.sh` | Tests, builds and zips a release. |
| `scripts/mock-service.py` | An OpenAI-compatible fake that streams, fails or answers in one piece. |
| `scripts/make-icon.swift` | Cuts the app icon and `.icns` out of `app/Resources/Trot-artwork.png`. |
| `.github/workflows/ci.yml` | Builds and tests on every push. |
