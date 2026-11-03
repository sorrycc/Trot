# Local Index-Translate

Trot can use [Bilibili's Index-Translate](https://github.com/bilibili/Index-Translate)
text models through a local OpenAI-compatible `/v1/chat/completions` server.
Trot is the client: it does not download weights, install an inference runtime,
or start a server. Existing services and the default Mon selection stay unchanged.

## Start a model server

Follow the project's [local text inference guide](https://github.com/bilibili/Index-Translate/blob/main/inference/llm/README.md)
for current dependencies, weights and hardware requirements.

- **Mac:** the official guide includes GGUF models with `llama-server` from
  llama.cpp. Bind to `127.0.0.1`, choose your port and set a model alias.
  Its example uses `Index-Translate-9B`; enter exactly that alias in Trot.
- **A machine with a supported GPU:** the official guide also supports vLLM
  and SGLang. The vLLM example serves `IndexTeam/Index-Translate-9B` on port 8000.
  For private on-device use, the server must run on the same Mac; a server on
  another machine receives the text you send it.

Use the **local inference** instructions, not the repository's
`call_api.py --serve` mode: that mode proxies a hosted API and is not local inference.
The upstream code and 9B model list Apache-2.0 licenses; no weights are bundled in Trot.

## Configure Trot

1. Open **Settings > Services** and select **Index-Translate**.
2. Set **Base URL** to the server's OpenAI API base, including `/v1`.
   The default is `http://127.0.0.1:8000/v1`. For llama-server on port 8080,
   use `http://127.0.0.1:8080/v1`.
3. Set **Model** to the exact model ID or alias exposed by the server.
   The default is `IndexTeam/Index-Translate-9B`, not the shorter llama-server alias.
4. Leave **API key** empty unless you enabled authentication on your server.
5. Click **Test**. In the translation panel, **⌘6** selects Index-Translate.
   The previous five service shortcuts keep their order.

The adapter follows the official text example: a single user translation prompt,
temperature 0, up to 1024 output tokens and `enable_thinking: false`. It accepts
all languages Trot already offers. Screenshots still use Trot's macOS OCR first;
this integration does not send images to a multimodal model.

Translation text is sent only to the configured inference endpoint, with no
cloud fallback. Redirects are rejected. Keep the URL on loopback for on-device
translation; use HTTPS and authentication if you deliberately use a remote host.
This does not disable Trot's existing account sync, update checks or crash reporting.
If signed in to Mon, base URLs and model names sync as other service settings do;
API keys remain on this Mac.

## Troubleshooting

- **Connection refused:** start the server and check its host and port.
- **404 or unknown model:** verify `/v1` and the model name/alias. A full
  `/v1/chat/completions` URL pasted into Settings is normalized automatically.
- **401/403:** enter the API key configured on that server.
- **Waiting for output:** this adapter returns a complete response, not a token
  stream. Local inference can be slow; requests have a three-minute deadline.
  Closing the panel cancels the request. Use a smaller quantization or shorter text
  if your hardware cannot finish within the deadline.
- **Cut-off translation:** the server reported the 1024-token output limit.
  Retry with shorter source text. Incomplete output is not shown as a finished translation.
- **Invalid response:** check that the server supports OpenAI chat completions
  and returns a nonempty message. Leading `<think>…</think>` reasoning blocks are
  removed; unfinished leading blocks are rejected. Literal tags within the
  translation, inline code or fenced examples are preserved.
