# Changelog

The update window shows the section of the version it offers. Every release
needs a `## <version>` section here, or its build fails.

## 0.6.0

- Sign in with a [Mon](https://mon.sorrycc.dev) account, with GitHub or Google, from **Settings > Services**.
- The new Mon service translates with no API key, 500,000 tokens a day on a free account.
- New installs start with Mon; an install that used OpenAI Compatible keeps it.
- Signed in, Trot syncs languages, service, models and shortcuts between Macs; API keys stay put.
- The first sync of a Mac with its own settings asks whose to keep.
- The menu bar menu shows the account, the last sync, **Sync Settings Now**, **Manage Account** and **Sign Out**.
- Crash reports go to Mon anonymously at the next launch; **Settings > General** turns them off.
- The Claude service shows Thinking… while a model reasons, as OpenAI Compatible does.
- `⌘1` to `⌘5` pick the service in the panel, Mon first.
- The panel and Settings animate smoothly throughout; Reduce Motion turns the movement off.
- Settings resizes smoothly to each pane, which fades in.
- The panel has a hairline edge and a fainter line between the source and the translation.
- A spinner shows while Trot reads the selection or a screenshot.
- A shimmering placeholder holds the first line's place until the translation starts.
- Long translations, and translations with line breaks, stream in with much less work per frame.
- The panel uses about half the processor while a translation streams in or Trot waits.
- Settings has a toolbar of icons for its panes, as macOS Settings windows do.
- **Settings > General** groups its rows into languages, the system and crash reports.
- A permission not granted shows a warning sign, and a check pops in once macOS grants it.
- **About** has **Check for Updates…**.
- Labels and controls stay in place from one Settings pane to the next.
- **Test** in Settings shows a check once a test translation works.
- Input hints show as keys, and a hint folds away as typing starts.
- **Copy** says Copied in the footer for a moment.
- An error shakes as it comes in, and its button is the default, so `Return` presses it.
- A pinned panel's edge takes the accent color.
- Speak, Copy's check and the pin pop in, and Stop glows while the translation is read aloud.
- The language and service chips resize and crossfade smoothly as they change.
- A hairline under a long translation shows while more of it is below.
- Paragraphs are spaced half a line apart, and the card has a little more room.
- Settings shows shortcuts as keycaps, and one being recorded glows until the keys are pressed.
- **Settings > Shortcuts** uses sentence case and shows a shortcut's reset button only once it is changed.
- On **Settings > Services**, the API key's note sits under the field with **Get an API key** after it.

## 0.5.0

- Trot is rewritten in Go with [MyGo](https://github.com/egoist/mygo) and runs on macOS 13 or later.
- Trot checks for updates once a day and shows the release notes before installing.
- **Check for Updates…** is in the menu bar menu and the Trot menu.
- Settings live in `~/Library/Application Support/Trot/settings.json`.
- The first launch copies the earlier Trot's settings, API keys and shortcuts included.
- The panel uses the system's popover material under a tint in place of Liquid Glass.
- Recording a shortcut in Settings pauses Trot's hotkeys, so a shortcut in use like `⌥D` can be recorded.
- A crash leaves its report in `crash.log` in the settings folder, and the last ten in `crashes`.
- Releases are signed and notarized, so macOS opens them without a warning and updates keep permissions.
- Because the app is new, macOS asks for Accessibility and Screen Recording again.

Versions before this one were the Swift app; its history is in Git.
