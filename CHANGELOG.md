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
- Settings has a toolbar of icons for its panes, as macOS Settings windows
  do, which crossfades from one pane's tab to the next, and General groups
  its rows into languages, the system and crash reports. A permission not
  granted shows a warning sign, and About has Check for Updates….
- The labels and controls of Settings stay in place from pane to pane.
- General reads the permissions and Open at Login once a second instead of
  in every frame it draws.
- A translation with line breaks, as a list, streams in with about a
  thirteenth of the work per frame, as only its last line is laid out
  again, and a long line streams in batches a little further apart, so it
  is laid out a half to a third as often.
- In the panel, the input hints show as keys, Copy says Copied in the
  footer for a moment, an error shakes as it comes in, and a pinned panel's
  edge takes the accent color.
- In the panel, Speak scales and fades in as a translation finishes, copy's
  check pops in for each copy, and the chips grow and shrink smoothly to
  their text, as Auto becomes the language detected.
- Until the first word of a translation arrives, a line of placeholder
  with a band of light sweeping across it holds its place, at the height
  of the first line, so the panel doesn't move as the word lands.
- A hint in the panel that typing takes away fades as it folds up, so the
  keys under it slide up rather than jump.
- Settings shows each shortcut as its keys, as keycaps. A shortcut being
  recorded takes a soft wash of the accent under an edge that breathes
  until the keys are pressed, and the icon of the tab picked pops.
- The panel casts its shadow again once, after a translation stops
  growing, rather than once for every line that streams in.
- The panel's card sinks back a little as the panel fades out, as it
  rises in as the panel appears. The pin pops in as the panel is pinned,
  and Stop glows and dims while the translation is read aloud.
- An error's button in the panel is the default button, in the accent,
  as Return presses it.
- A translation taller than the panel shows a hairline under it while
  more of it is below, which fades as the end scrolls into view, and the
  service chip crossfades to the service picked.
- A blank line between paragraphs of a translation leaves half a line of
  space rather than a whole one, the card has a little more room above
  and below, and the chips stay in place in input mode, where the pin
  doesn't show.
- In Settings, Test's check pops in once a test translation works, and a
  permission's check pops in as macOS grants it.
- The panel takes about half the processor while a translation streams in
  or Trot waits for its first word: the breathing status, the caret, Stop
  and a shortcut being recorded pulse at thirty frames a second, and the
  placeholder's band of light sweeps at sixty, not at every frame of the
  display.
- On Settings > Shortcuts the names are in sentence case, as the other
  labels are, the note lines up under the shortcuts, and a shortcut's
  reset button shows only once it differs from the default. About's
  description fits on one line.
- On Settings > Services the API key's note sits right under the field,
  as the other rows' notes do, with Get an API key after it, and says in
  one line that the key is saved on this Mac and sent only to the service.

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
