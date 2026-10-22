# Changelog

The update window shows the section of the version it offers. Every release
needs a `## <version>` section here, or its build fails.

## Unreleased

- Sign in with your [Mon](https://mon.sorrycc.dev) account, with GitHub or
  Google, from Settings > Services or the menu bar menu, and translate with
  the new Mon service: no API key, and 500,000 tokens a day on a free
  account. Mon is the service a new install starts with; an install that
  used OpenAI Compatible keeps it.
- Signed in, Trot syncs its settings between your Macs: the languages, the
  service, the base URLs and models, and the shortcuts. API keys stay on
  each Mac. The first sync of a Mac with settings of its own asks whose to
  keep.
- The menu bar menu shows the account, when the settings last synced, Sync
  Settings Now, Manage Account and Sign Out.
- Crash reports go to Mon at the next launch, anonymously and with the home
  folder taken out. Settings > General turns them off.
- The Claude service notes when a model thinks before it answers, and so
  shows Thinking… in the panel, as OpenAI Compatible does.
- ⌘1 to ⌘5 pick the service in the panel, Mon first.
- The panel and Settings move more smoothly: the panel settles into place
  as it appears, a new translation or notice rises in, buttons fade their
  fill under the mouse and give a little as they are pressed, the chips'
  chevrons turn while their menu is open, copy's check and the pin replace
  their icons in place, and the status breathes while Trot waits. Settings
  grows and shrinks smoothly to each pane, which fades in. Reduce Motion
  turns the movement off.
- The panel has a hairline edge, and a fainter line between the source and
  the translation. A spinner shows while Trot reads the selection or a
  screenshot, and Test in Settings shows a check once a test translation
  works.
- A long translation of several paragraphs streams in with about a third
  of the work per frame, as only its last paragraph is laid out again, and
  About's icon is decoded when About first shows rather than at launch.

## 0.5.0

- Trot is rewritten in Go and draws its own interface with
  [MyGo](https://github.com/egoist/mygo): one binary, no Swift toolchain to
  build it, and macOS 13 or later instead of macOS 26.
- Trot updates itself: it checks for a new version once a day, and from
  **Check for Updates…** in the menu bar menu and the Trot menu, and shows
  the release notes before installing.
- Settings live in `~/Library/Application Support/Trot/settings.json`. The
  first launch copies the settings of the earlier Trot, API keys and
  shortcuts included.
- The panel's background is the system's popover material under a tint, in
  place of Liquid Glass, and still reads the same over light and dark
  windows.
- Recording a shortcut in Settings pauses Trot's hotkeys, so a shortcut
  Trot already uses, such as ⌥D, can be recorded again.
- A crash leaves its report in `crash.log` in the settings folder, and the
  last ten in `crashes`.
- Releases are signed with a Developer ID and notarized, so macOS opens
  them without a warning, and updates keep Trot's permissions.
- Because the app is new, macOS asks for Accessibility and Screen Recording
  again.

Versions before this one were the Swift app; its history is in Git.
