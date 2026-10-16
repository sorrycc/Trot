# Changelog

The update window shows the section of the version it offers. Every release
needs a `## <version>` section here, or its build fails.

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
