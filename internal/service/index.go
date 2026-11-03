package service

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"

	"trot/internal/lang"
)

// The official text inference example uses a single user message, no thinking,
// and a non-streaming response. A local CPU/GPU may need longer than the usual
// 30-second first-byte timeout; the shared three-minute deadline still applies.
var indexClient = func() *http.Client {
	transport := client.Transport.(*http.Transport).Clone()
	transport.ResponseHeaderTimeout = totalTimeout
	return &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error {
		// Never forward selected text or a key to a redirected inference endpoint.
		return http.ErrUseLastResponse
	}}
}()

func indexPrompt(text string, source, target lang.Language) string {
	from := ""
	if source != "" {
		from = source.EnglishName()
	}
	return "请将以下" + from + "文本翻译为" + target.EnglishName() + "，直接输出翻译结果，不要进行任何解释。\n\n" + strings.TrimSpace(text)
}

func translateIndex(ctx context.Context, c Config, text string, source, target lang.Language, emit func(Chunk)) error {
	body, err := json.Marshal(map[string]any{
		"model":                c.Model,
		"messages":             []map[string]string{{"role": "user", "content": indexPrompt(text, source, target)}},
		"stream":               false,
		"temperature":          0,
		"max_tokens":           1024,
		"chat_template_kwargs": map[string]bool{"enable_thinking": false},
	})
	if err != nil {
		return err
	}
	headers := map[string]string{}
	if c.APIKey != "" {
		headers["Authorization"] = "Bearer " + c.APIKey
	}
	r, err := postUsing(ctx, c.BaseURL+"/chat/completions", headers, body, "application/json", indexClient, false)
	if err != nil {
		return err
	}
	defer r.Close()
	// Bound a malformed server response, including any unexpected reasoning.
	const maxResponse = 8 << 20
	data, err := io.ReadAll(io.LimitReader(r, maxResponse+1))
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return err
	}
	if len(data) > maxResponse {
		return ErrInvalidResponse
	}
	var reply struct {
		Error   json.RawMessage `json:"error"`
		Choices []struct {
			Message struct {
				Content string `json:"content"`
				Refusal string `json:"refusal"`
			} `json:"message"`
			FinishReason string `json:"finish_reason"`
		} `json:"choices"`
	}
	if json.Unmarshal(data, &reply) != nil {
		return ErrInvalidResponse
	}
	if len(reply.Error) > 0 && string(reply.Error) != "null" {
		return &RefusedError{ErrorMessage(data)}
	}
	if len(reply.Choices) == 0 {
		return ErrInvalidResponse
	}
	choice := reply.Choices[0]
	if choice.FinishReason == "length" {
		return ErrTruncated
	}
	if choice.FinishReason == "content_filter" || choice.Message.Refusal != "" {
		return &RefusedError{choice.Message.Refusal}
	}
	result := strings.TrimSpace(choice.Message.Content)
	// Only leading blocks are reasoning; tags in the translation may be literal.
	for strings.HasPrefix(result, "<think>") {
		_, after, ok := strings.Cut(result, "</think>")
		if !ok {
			return ErrInvalidResponse
		}
		result = strings.TrimSpace(after)
	}
	if result == "" {
		return ErrInvalidResponse
	}
	emit(Chunk{Text: result})
	return nil
}
