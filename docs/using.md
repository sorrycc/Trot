# Using Trot

Trot sits in the menu bar. Three hotkeys open its panel; the menu bar icon offers the same three actions and Settings.

## The panel

The panel is one floating card. From top to bottom:

- **Language chip**, such as `English → 简体中文`. The left side is the language Trot detected, the right the target. Click it to translate into another language.
- **Service picker**, which switches the service for this and later translations.
- **Pin**, which keeps the panel open when you click elsewhere. Without it, a click in another app closes the panel.
- **Close**, also Escape or ⌘W.
- The **source text** and the **translation**, which streams in as the service produces it. Both are selectable. ⌘C with nothing selected copies the whole translation.
- The **footer**, with the service and how long the translation took, or the error when one fails. The speaker button reads the translation aloud with the system voice for its language; the copy button copies it.

While a translation streams in, a blinking cursor marks where the next words will land.

When a translation fails, the footer says why. A missing or rejected key or a wrong base URL comes with an Open Settings button; anything else, such as a network error, with Retry, which runs the same text again with whatever service is active.

The panel opens below the mouse, or above it near the bottom of the screen, and stays within the screen. It fades and scales in, unless Reduce Motion is on in System Settings. Drag it anywhere by its background. Closing the panel stops the translation.

## The menu bar

The menu bar icon offers the three actions with their hotkeys, a Service submenu that switches the active service, Settings and Quit.

## Translating the selection (⌥D)

Select text in any app and press the hotkey. Trot reads the selection through Accessibility. When an app doesn't offer it that way, as browsers and Electron apps mostly don't, Trot checks that the app's Edit > Copy item is enabled, copies the selection with a synthesized ⌘C, and puts the clipboard back afterwards. Without a selection the panel opens in input mode instead.

Editors that copy the whole line when nothing is selected (VS Code, Cursor, Zed, Sublime Text) are never sent ⌘C without a selection, so a line of code never leaves the editor by accident. Clipboard managers that watch the pasteboard can still record a copied selection before Trot restores it.

With the panel itself in front, the hotkey translates the text selected inside the panel.

This needs the Accessibility permission. Trot asks at its first launch; Settings > General shows whether it's granted and opens System Settings.

## Translating typed text (⌥A)

The panel opens pinned with an editable field. Return translates, Shift+Return adds a line break. The result stays while you edit and translate again.

## Translating a screenshot (⌥S)

The system crosshair appears. Drag over a region; Escape cancels. Trot reads the text with the Vision framework, in Chinese, Japanese, Korean and English, joins the lines into paragraphs and translates them. The first time, macOS asks for Screen Recording. When the permission is missing, the panel says so with a button to System Settings; macOS usually needs Trot reopened after the permission is granted.

## Languages

Settings > General has two languages. Text in any other language is translated into the first; text already in the first is translated into the second. The defaults are Simplified Chinese and English. Detection runs on the device and uses the script for short text, so a few Chinese characters are never mistaken for Japanese. Chinese that could be either script, such as 你好, counts as whichever Chinese is among your two languages.

The chip in the panel overrides the target for the current text.
