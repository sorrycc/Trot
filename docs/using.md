# Using Trot

Trot sits in the menu bar. Three hotkeys open its panel; the menu bar icon offers the same three actions and Settings.

## The panel

The panel is one floating card. From top to bottom:

- **Language chip**, such as `English → 简体中文`. The left side is the language Trot detected, or Auto, the right the target. Click it, or press ⌘L, to translate into another language.
- **Service chip**, which switches the service for this and later translations. ⌘1 to ⌘4 pick one without the menu.
- **Pin** (⌘P), which keeps the panel open when you click elsewhere. Without it, a click in another app closes the panel.
- **Close**, also Escape or ⌘W.
- The **source text** and the **translation**, which streams in as the service produces it. Both are selectable. ⌘C with nothing selected copies the whole translation.
- The **footer**, with how long the translation took and, for an LLM service, the model. The speaker button reads the translation aloud with the system voice for its language; the copy button copies it.

While a translation streams in, the card grows smoothly with the text and an accent-coloured cursor marks where the next words will land. The cursor stays solid while words arrive and blinks when the stream goes quiet.

When a translation fails, a notice takes the place of the translation and says why. A missing or rejected key or a wrong base URL comes with an Open Settings button; anything else, such as a network error, with Retry, which runs the same text again with whatever service is active. Return presses the button. A translation the service cut off keeps what arrived, with the notice under it.

Selections longer than 20,000 characters are cut there, and the footer says so.

The panel opens below the mouse, or above it near the bottom of the screen, and stays within the screen. It fades and scales in and out, unless Reduce Motion is on in System Settings. Drag it anywhere by its background. Closing the panel stops the translation.

## The menu bar

The menu bar icon offers the three actions with their hotkeys, a Service submenu that switches the active service, About, Settings and Quit.

## Translating the selection (⌥D)

Select text in any app and press the hotkey. Trot reads the selection through Accessibility. When an app doesn't offer it that way, as browsers and Electron apps mostly don't, Trot checks that the app's Edit > Copy item is enabled, copies the selection with a synthesized ⌘C, and puts the clipboard back afterwards. Without a selection the panel opens in input mode instead.

Editors that copy the whole line when nothing is selected (VS Code, Cursor, Zed, Sublime Text) are never sent ⌘C without a selection, so a line of code never leaves the editor by accident. Clipboard managers that watch the pasteboard can still record a copied selection before Trot restores it.

When reading the selection takes a moment, as the pasteboard path in browsers can, the panel appears with "Reading the selection…" and fills in when the text arrives.

With the panel itself in front, the hotkey translates the text selected inside the panel.

This needs the Accessibility permission. Trot asks at its first launch; Settings > General shows whether it's granted and opens System Settings.

## Translating typed text (⌥A)

The panel opens pinned with an editable field. Return translates, Shift+Return adds a line break. Once translated, the typed text steps back to grey under the result; editing it brings it forward again. A target picked from the language chip holds while the panel stays open.

## Translating a screenshot (⌥S)

The system crosshair appears. Drag over a region; Escape cancels. The panel opens with "Reading the screenshot…" while Trot reads the text with the Vision framework, in Chinese, Japanese, Korean and English, joins the lines into paragraphs (Korean keeps its spaces) and translates them. The first time, macOS asks for Screen Recording. When the permission is missing, the panel says so with a button to System Settings; macOS usually needs Trot reopened after the permission is granted.

## Languages

Settings > General has a first and a second language. Text in any other language is translated into the first; text already in the first is translated into the second. The defaults are Simplified Chinese and English. Picking the same language for both swaps them. Detection runs on the device and uses the script for short text, so a few Chinese characters are never mistaken for Japanese. Chinese that could be either script, such as 你好, counts as whichever Chinese is among your two languages.

The chip in the panel overrides the target for the current text.
