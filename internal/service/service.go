// Package service sends text to a translation service and streams the
// translation back.
package service

import (
	"context"
	"strings"

	"trot/internal/lang"
)

// Kind is a translation service. One is active at a time.
type Kind string

const (
	OpenAI Kind = "openAI"
	Claude Kind = "claude"
	DeepL  Kind = "deepL"
	Google Kind = "google"
)

// Kinds are the services, in the order menus and ⌘1 to ⌘4 list them.
var Kinds = []Kind{OpenAI, Claude, DeepL, Google}

// ParseKind returns the service of a stored name.
func ParseKind(s string) (Kind, bool) {
	for _, k := range Kinds {
		if string(k) == s {
			return k, true
		}
	}
	return "", false
}

// DisplayName is the service's full name.
func (k Kind) DisplayName() string {
	switch k {
	case OpenAI:
		return "OpenAI Compatible"
	case Claude:
		return "Claude"
	case DeepL:
		return "DeepL"
	case Google:
		return "Google"
	}
	return string(k)
}

// ShortName is the name in the panel's chip and the menu bar menu.
func (k Kind) ShortName() string {
	if k == OpenAI {
		return "OpenAI"
	}
	return k.DisplayName()
}

// NeedsKey reports whether the service takes an API key.
func (k Kind) NeedsKey() bool { return k != Google }

// KeyPage is where the service hands out keys, "" for none.
func (k Kind) KeyPage() string {
	switch k {
	case OpenAI:
		return "https://platform.openai.com/api-keys"
	case Claude:
		return "https://console.anthropic.com/settings/keys"
	case DeepL:
		return "https://www.deepl.com/your-account/keys"
	}
	return ""
}

// HasBaseURL reports whether the base URL can be set.
func (k Kind) HasBaseURL() bool { return k == OpenAI || k == Claude }

// HasModel reports whether the service has models to choose from.
func (k Kind) HasModel() bool { return k == OpenAI || k == Claude }

// DefaultBaseURL is where requests go when none is set.
func (k Kind) DefaultBaseURL() string {
	switch k {
	case OpenAI:
		return "https://api.openai.com/v1"
	case Claude:
		return "https://api.anthropic.com"
	}
	return ""
}

// DefaultModel is the model used when none is set.
func (k Kind) DefaultModel() string {
	switch k {
	case OpenAI:
		return "gpt-4o-mini"
	case Claude:
		return "claude-opus-5-5"
	}
	return ""
}

// Config is a service's settings.
type Config struct {
	BaseURL string // tidied, see NormalizeBaseURL
	APIKey  string
	Model   string
}

// Host is where requests of the service go, for opening the connection
// ahead of them.
func (k Kind) Host(c Config) string {
	switch k {
	case DeepL:
		return deepLHost(c.APIKey)
	case Google:
		return googleHost
	}
	return c.BaseURL
}

// NormalizeBaseURL returns raw as a base URL the service's paths append
// to: a scheme when there is none (plain http for a machine on the desk,
// which rarely speaks TLS), no trailing slashes, and without the path of
// the endpoint itself, which is pasted along more often than not.
func NormalizeBaseURL(raw string, k Kind) string {
	url := strings.TrimSpace(raw)
	if url == "" {
		return ""
	}
	if !strings.Contains(url, "://") {
		host, _, _ := strings.Cut(url, "/")
		if isLocal(host) {
			url = "http://" + url
		} else {
			url = "https://" + url
		}
	}
	url = strings.TrimRight(url, "/")
	var endpoints []string
	switch k {
	case OpenAI:
		endpoints = []string{"/chat/completions"}
	case Claude:
		endpoints = []string{"/v1/messages", "/v1"}
	}
	for _, e := range endpoints {
		if strings.HasSuffix(url, e) {
			url = strings.TrimSuffix(url, e)
			break
		}
	}
	return url
}

// isLocal reports loopback and link-local names, with or without a port.
func isLocal(host string) bool {
	name := strings.ToLower(host)
	if strings.HasPrefix(name, "[") {
		return strings.HasPrefix(name, "[::1]")
	}
	if i := strings.LastIndex(name, ":"); i >= 0 {
		name = name[:i]
	}
	return name == "localhost" || strings.HasPrefix(name, "127.") || name == "0.0.0.0" || strings.HasSuffix(name, ".local")
}

// Chunk is a piece of a translation stream: more text, or a note that the
// model reasons before it answers, which can take a while with nothing to
// show.
type Chunk struct {
	Text     string
	Thinking bool
}

// Translate sends text to the service, from source ("" when unknown) into
// target, and calls emit with each piece of the translation as it comes,
// on the calling goroutine. Services without streaming emit the whole
// translation once. It returns when the translation is complete, ctx is
// done, or it fails.
func Translate(ctx context.Context, k Kind, c Config, text string, source, target lang.Language, emit func(Chunk)) error {
	switch k {
	case OpenAI:
		return translateOpenAI(ctx, c, text, source, target, emit)
	case Claude:
		return translateClaude(ctx, c, text, source, target, emit)
	case DeepL:
		return translateDeepL(ctx, c, text, source, target, emit)
	case Google:
		return translateGoogle(ctx, text, source, target, emit)
	}
	return ErrInvalidResponse
}

// SystemPrompt is the instructions the LLM services share.
func SystemPrompt(source, target lang.Language) string {
	from := ""
	if source != "" {
		from = "from " + source.EnglishName() + " "
	}
	t := target.EnglishName()
	return "You are a translation engine. Translate the text the user sends " + from + "into " + t + ".\n" +
		"Reply with the translation only: no explanations, no notes, no quotation marks around it.\n" +
		"Keep the line breaks, lists and inline formatting of the original.\n" +
		"If the text is already in " + t + ", return it unchanged.\n" +
		"Technical terms, code, product names and URLs stay as they are."
}
