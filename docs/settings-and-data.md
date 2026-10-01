# Settings and data

## Settings

Settings opens from the menu bar icon or with ⌘, while a Trot window is key. Changes save as you make them.

| Pane | Setting | Default | Notes |
|---|---|---|---|
| General | Translate into | 简体中文 | The target for text in any other language |
| General | And from it into | English | The target for text already in the first language |
| General | Open Trot at login | off | Through the system login items |
| General | Accessibility | | Shows whether the permission is granted |
| Services | Service | OpenAI Compatible | The active service, also switchable in the panel |
| Services | Base URL | per service | OpenAI Compatible: `https://api.openai.com/v1`. Claude: `https://api.anthropic.com`. Point it at DeepSeek, Qwen, Ollama or a proxy |
| Services | API key | empty | DeepL keys ending in `:fx` use the free API |
| Services | Model | per service | OpenAI Compatible: `gpt-4o-mini`. Claude: `claude-opus-5-5` |
| Services | Test | | Translates a sentence with the current settings and shows the result or the error |
| Shortcuts | Translate Selection | ⌥D | Click, then press a combination with ⌘, ⌥ or ⌃. Delete clears it |
| Shortcuts | Translate Input | ⌥A | |
| Shortcuts | Translate Screenshot | ⌥S | |

Shortcuts are registered system-wide through Carbon hotkeys, which work without the Accessibility permission. When another app already holds a combination, the pane says so.

## Services

| Service | How | Streams |
|---|---|---|
| OpenAI Compatible | `POST {base}/chat/completions` with a translation system prompt. A gateway that ignores `stream` and answers with one JSON message works too | yes |
| Claude | `POST {base}/v1/messages`. Claude 5 models run at low effort with Anthropic's server-side fallback, so a safety decline reruns on a fallback model | yes |
| DeepL | `POST /v2/translate` on the free or Pro host, chosen by the key's suffix | no |
| Google | The `translate_a/single` endpoint Google's web client uses, with the text in a form body. No key. Unofficial, so it can stop working | no |

Requests give up after 30 seconds without data and 3 minutes in all. A reply that isn't a translation, such as a web page from a wrong base URL, is shown as an error rather than an empty result, and so is a translation the service cut off at its output limit. Errors that Settings can fix, a missing or rejected key or a wrong base URL, come with an Open Settings button.

## Data

Settings, API keys included, live in the app's user defaults, `dev.sorrycc.trot`. The keychain is not used: an ad-hoc signed app has a new identity after every build, and the keychain would ask for permission each time. Trot keeps no history and sends text only to the service you chose.

## Launch arguments

For trying the app from a script:

```sh
open build/Trot.app --args -translate "Hello"        # open the panel with that text
open build/Trot.app --args -input YES                # open the input panel
open build/Trot.app --args -settings Services        # open a Settings pane
open build/Trot.app --args -preview YES -translate … # show the panel without taking the keyboard
```
