package service

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"trot/internal/lang"
)

// translateOpenAI uses any chat completions endpoint: OpenAI, DeepSeek,
// Qwen, Ollama and others.
func translateOpenAI(ctx context.Context, c Config, text string, source, target lang.Language, emit func(Chunk)) error {
	if c.APIKey == "" {
		return &MissingKeyError{OpenAI}
	}
	body := map[string]any{
		"model":       c.Model,
		"stream":      true,
		"temperature": 0.2,
		"messages": []map[string]string{
			{"role": "system", "content": SystemPrompt(source, target)},
			{"role": "user", "content": text},
		},
	}
	r, err := postJSON(ctx, c.BaseURL+"/chat/completions", map[string]string{"Authorization": "Bearer " + c.APIKey}, body)
	if err != nil {
		return err
	}
	defer r.Close()
	// Reasoning arrives token by token; the panel needs to hear of it once.
	saidThinking := false
	err = events(r, func(event map[string]any) error {
		if e, ok := event["error"].(map[string]any); ok {
			msg, _ := e["message"].(string)
			return &RefusedError{msg}
		}
		choices, _ := event["choices"].([]any)
		if len(choices) == 0 {
			return nil
		}
		first, _ := choices[0].(map[string]any)
		if delta, ok := first["delta"].(map[string]any); ok {
			if chunk, ok := OpenAIChunk(delta); ok && (!chunk.Thinking || !saidThinking) {
				saidThinking = saidThinking || chunk.Thinking
				emit(chunk)
			}
		}
		switch first["finish_reason"] {
		case "length":
			return ErrTruncated
		case "content_filter":
			return &RefusedError{}
		}
		return nil
	})
	var ns *NotAStreamError
	if !errors.As(err, &ns) {
		return err
	}
	// A gateway that ignored stream sends the whole completion at once.
	var whole struct {
		Choices []struct {
			FinishReason string `json:"finish_reason"`
			Message      *struct {
				Content *string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if json.Unmarshal(ns.Body, &whole) != nil || whole.Choices == nil {
		return err
	}
	if len(whole.Choices) > 0 && whole.Choices[0].FinishReason == "content_filter" {
		return &RefusedError{}
	}
	if len(whole.Choices) == 0 || whole.Choices[0].Message == nil || whole.Choices[0].Message.Content == nil {
		return err
	}
	emit(Chunk{Text: *whole.Choices[0].Message.Content})
	if whole.Choices[0].FinishReason == "length" {
		return ErrTruncated
	}
	return nil
}

// OpenAIChunk is what a streamed delta carries: text, or reasoning, which
// DeepSeek and Qwen send as reasoning_content and OpenRouter and Ollama as
// reasoning. Reasoning is never shown, only noted.
func OpenAIChunk(delta map[string]any) (Chunk, bool) {
	if s, _ := delta["content"].(string); s != "" {
		return Chunk{Text: s}, true
	}
	for _, key := range []string{"reasoning_content", "reasoning"} {
		if s, _ := delta[key].(string); s != "" {
			return Chunk{Thinking: true}, true
		}
	}
	return Chunk{}, false
}

// IsClaude5 reports a Claude 5 model, which thinks by default.
func IsClaude5(model string) bool {
	for _, p := range []string{"claude-opus-5", "claude-sonnet-5", "claude-fable-5", "claude-mythos-5"} {
		if strings.HasPrefix(model, p) {
			return true
		}
	}
	return false
}

// translateClaude uses the Anthropic Messages API, streamed.
func translateClaude(ctx context.Context, c Config, text string, source, target lang.Language, emit func(Chunk)) error {
	if c.APIKey == "" {
		return &MissingKeyError{Claude}
	}
	body := map[string]any{
		"model":      c.Model,
		"max_tokens": 16000,
		"stream":     true,
		"system":     SystemPrompt(source, target),
		"messages":   []map[string]string{{"role": "user", "content": text}},
	}
	headers := map[string]string{"x-api-key": c.APIKey, "anthropic-version": "2023-06-01"}
	// Claude 5 models think by default; translation needs little of it, and
	// low effort keeps the first token quick. A safety decline on these
	// models reruns the request on a fallback model.
	if IsClaude5(c.Model) {
		body["output_config"] = map[string]string{"effort": "low"}
		body["fallbacks"] = "default"
		headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
	}
	r, err := postJSON(ctx, c.BaseURL+"/v1/messages", headers, body)
	if err != nil {
		return err
	}
	defer r.Close()
	err = events(r, func(event map[string]any) error {
		switch event["type"] {
		case "content_block_delta":
			delta, _ := event["delta"].(map[string]any)
			if delta["type"] == "text_delta" {
				if s, ok := delta["text"].(string); ok {
					emit(Chunk{Text: s})
				}
			}
		case "message_delta":
			delta, _ := event["delta"].(map[string]any)
			switch delta["stop_reason"] {
			case "refusal":
				details, _ := event["stop_details"].(map[string]any)
				reason, _ := details["explanation"].(string)
				return &RefusedError{reason}
			case "max_tokens", "model_context_window_exceeded":
				return ErrTruncated
			}
		case "error":
			e, _ := event["error"].(map[string]any)
			msg, _ := e["message"].(string)
			return &RefusedError{msg}
		}
		return nil
	})
	var ns *NotAStreamError
	if !errors.As(err, &ns) {
		return err
	}
	// A proxy that ignored stream sends the whole message at once.
	var whole struct {
		Content []struct {
			Type string  `json:"type"`
			Text *string `json:"text"`
		} `json:"content"`
		StopReason string `json:"stop_reason"`
	}
	if json.Unmarshal(ns.Body, &whole) != nil {
		return err
	}
	for _, block := range whole.Content {
		if block.Type == "text" && block.Text != nil {
			emit(Chunk{Text: *block.Text})
			if whole.StopReason == "max_tokens" {
				return ErrTruncated
			}
			return nil
		}
	}
	return err
}

// deepLHost: free keys end in :fx and have a host of their own.
func deepLHost(key string) string {
	if strings.HasSuffix(key, ":fx") {
		return "https://api-free.deepl.com"
	}
	return "https://api.deepl.com"
}

// DeepLTarget is a target language as DeepL names it.
func DeepLTarget(l lang.Language) string {
	switch l {
	case lang.English:
		return "EN-US"
	case lang.ChineseSimplified:
		return "ZH-HANS"
	case lang.ChineseTraditional:
		return "ZH-HANT"
	case lang.Portuguese:
		return "PT-BR"
	}
	return strings.ToUpper(string(l))
}

// DeepLSource is a source language as DeepL names it.
func DeepLSource(l lang.Language) string {
	if l.SameFamily(lang.ChineseSimplified) {
		return "ZH"
	}
	return strings.ToUpper(string(l))
}

func translateDeepL(ctx context.Context, c Config, text string, source, target lang.Language, emit func(Chunk)) error {
	if c.APIKey == "" {
		return &MissingKeyError{DeepL}
	}
	body := map[string]any{"text": []string{text}, "target_lang": DeepLTarget(target)}
	// The service detects Latin-script languages better than a local guess
	// on a short string; a CJK script is certain either way.
	if source != "" && source.ScriptCertain() {
		body["source_lang"] = DeepLSource(source)
	}
	data, err := json.Marshal(body)
	if err != nil {
		return err
	}
	reply, err := postForData(ctx, deepLHost(c.APIKey)+"/v2/translate",
		map[string]string{"Authorization": "DeepL-Auth-Key " + c.APIKey}, data, "application/json")
	if err != nil {
		return err
	}
	var v struct {
		Translations []struct {
			Text *string `json:"text"`
		} `json:"translations"`
	}
	if json.Unmarshal(reply, &v) != nil || len(v.Translations) == 0 || v.Translations[0].Text == nil {
		return ErrInvalidResponse
	}
	emit(Chunk{Text: *v.Translations[0].Text})
	return nil
}

const googleHost = "https://translate.googleapis.com"

// GoogleCode is a language as Google names it.
func GoogleCode(l lang.Language) string {
	switch l {
	case lang.ChineseSimplified:
		return "zh-CN"
	case lang.ChineseTraditional:
		return "zh-TW"
	}
	return string(l)
}

// translateGoogle uses the endpoint Google's web client uses. No key, but
// unofficial, so it can stop working without notice.
func translateGoogle(ctx context.Context, text string, source, target lang.Language, emit func(Chunk)) error {
	sl := "auto"
	if source != "" && source.ScriptCertain() {
		sl = GoogleCode(source)
	}
	// The text goes in a form body, where "+" and "&" are escaped and long
	// selections don't run into URL length limits.
	u := googleHost + "/translate_a/single?client=gtx&dt=t&sl=" + sl + "&tl=" + GoogleCode(target)
	reply, err := postForData(ctx, u, map[string]string{"User-Agent": "Mozilla/5.0"},
		FormBody([][2]string{{"q", text}}), "application/x-www-form-urlencoded; charset=utf-8")
	if err != nil {
		return err
	}
	// [[["translated", "source", null, null, 10], ...], null, "en", ...]
	var v []any
	if json.Unmarshal(reply, &v) != nil || len(v) == 0 {
		return ErrInvalidResponse
	}
	sentences, ok := v[0].([]any)
	if !ok {
		return ErrInvalidResponse
	}
	var b strings.Builder
	for _, s := range sentences {
		if parts, ok := s.([]any); ok && len(parts) > 0 {
			if t, ok := parts[0].(string); ok {
				b.WriteString(t)
			}
		}
	}
	emit(Chunk{Text: b.String()})
	return nil
}
