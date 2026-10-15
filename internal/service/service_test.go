package service

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"trot/internal/lang"
)

func TestFormBodyEscapesReservedCharacters(t *testing.T) {
	got := string(FormBody([][2]string{{"q", "a+b&c=d e/ü"}, {"tl", "zh-CN"}}))
	if want := "q=a%2Bb%26c%3Dd%20e%2F%C3%BC&tl=zh-CN"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestErrorMessage(t *testing.T) {
	cases := map[string]string{
		`{"error":{"message":"Invalid API key","type":"auth"}}`: "Invalid API key",
		`{"message":"Wrong endpoint"}`:                          "Wrong endpoint",
		`{"error":"quota exceeded"}`:                            "quota exceeded",
		"  Service Unavailable \n":                              "Service Unavailable",
		"<html><body>404</body></html>":                         "",
		`{"detail":"something"}`:                                "",
		strings.Repeat("x", 500):                                "",
	}
	for body, want := range cases {
		if got := ErrorMessage([]byte(body)); got != want {
			t.Errorf("ErrorMessage(%q) = %q, want %q", body, got, want)
		}
	}
}

func TestNormalizeBaseURL(t *testing.T) {
	cases := []struct {
		raw  string
		kind Kind
		want string
	}{
		{"api.openai.com/v1", OpenAI, "https://api.openai.com/v1"},
		{"https://api.openai.com/v1/chat/completions", OpenAI, "https://api.openai.com/v1"},
		{"https://api.openai.com/v1//", OpenAI, "https://api.openai.com/v1"},
		{"https://api.anthropic.com/v1", Claude, "https://api.anthropic.com"},
		{"https://api.anthropic.com/v1/messages", Claude, "https://api.anthropic.com"},
		{"http://localhost:11434/v1", OpenAI, "http://localhost:11434/v1"},
		{"localhost:11434/v1", OpenAI, "http://localhost:11434/v1"},
		{"127.0.0.1:8080/v1/", OpenAI, "http://127.0.0.1:8080/v1"},
		{"mini.local:1234/v1", OpenAI, "http://mini.local:1234/v1"},
		{"api.deepseek.com", OpenAI, "https://api.deepseek.com"},
		{"  ", OpenAI, ""},
	}
	for _, c := range cases {
		if got := NormalizeBaseURL(c.raw, c.kind); got != c.want {
			t.Errorf("NormalizeBaseURL(%q) = %q, want %q", c.raw, got, c.want)
		}
	}
}

func TestBadURLFailsBeforeAnyRequest(t *testing.T) {
	for _, u := range []string{"not a url", "/chat/completions"} {
		_, err := postForData(context.Background(), u, nil, nil, "application/json")
		var bad *BadURLError
		if !errors.As(err, &bad) {
			t.Errorf("%q: %v", u, err)
		}
	}
}

func TestParseEvent(t *testing.T) {
	if ParseEvent(`{"a":1}`)["a"] != 1.0 {
		t.Error("json")
	}
	if len(ParseEvent("nope")) != 0 {
		t.Error("garbage")
	}
}

func TestOpenAIChunk(t *testing.T) {
	cases := []struct {
		delta map[string]any
		want  Chunk
		ok    bool
	}{
		{map[string]any{"content": "api"}, Chunk{Text: "api"}, true},
		// DeepSeek sends a null content beside the reasoning.
		{map[string]any{"content": nil, "reasoning_content": "The user"}, Chunk{Thinking: true}, true},
		{map[string]any{"reasoning": "Hmm"}, Chunk{Thinking: true}, true},
		{map[string]any{"content": "", "reasoning_content": nil}, Chunk{}, false},
		{map[string]any{"role": "assistant", "content": "", "reasoning_content": ""}, Chunk{}, false},
	}
	for _, c := range cases {
		if got, ok := OpenAIChunk(c.delta); got != c.want || ok != c.ok {
			t.Errorf("OpenAIChunk(%v) = %v %v", c.delta, got, ok)
		}
	}
}

func TestEveryServiceKnowsWhatItNeeds(t *testing.T) {
	if Google.NeedsKey() || Google.KeyPage() != "" {
		t.Error("Google needs nothing")
	}
	for _, k := range Kinds {
		if k != Google && (!k.NeedsKey() || !strings.HasPrefix(k.KeyPage(), "https://")) {
			t.Errorf("%s key", k)
		}
		if k.HasBaseURL() && (!strings.HasPrefix(k.DefaultBaseURL(), "https://") || k.DefaultModel() == "") {
			t.Errorf("%s defaults", k)
		}
		if p, ok := ParseKind(string(k)); !ok || p != k {
			t.Errorf("ParseKind(%s)", k)
		}
	}
}

func TestLanguageCodes(t *testing.T) {
	checks := map[string]string{
		DeepLTarget(lang.English):            "EN-US",
		DeepLTarget(lang.ChineseSimplified):  "ZH-HANS",
		DeepLTarget(lang.German):             "DE",
		DeepLSource(lang.ChineseTraditional): "ZH",
		GoogleCode(lang.ChineseTraditional):  "zh-TW",
		GoogleCode(lang.Japanese):            "ja",
		deepLHost("abc:fx"):                  "https://api-free.deepl.com",
		deepLHost("abc"):                     "https://api.deepl.com",
	}
	for got, want := range checks {
		if got != want {
			t.Errorf("got %q, want %q", got, want)
		}
	}
}

func TestIsClaude5(t *testing.T) {
	if !IsClaude5("claude-opus-5-5") || !IsClaude5("claude-sonnet-5-5") || IsClaude5("claude-3-5-sonnet-latest") {
		t.Error("IsClaude5")
	}
}

func TestSystemPrompt(t *testing.T) {
	p := SystemPrompt(lang.English, lang.ChineseSimplified)
	if !strings.Contains(p, "from English") || !strings.Contains(p, "into Simplified Chinese") {
		t.Error(p)
	}
	if strings.Contains(SystemPrompt("", lang.Japanese), "from ") {
		t.Error("no source")
	}
}

func TestErrorsReadAsSentences(t *testing.T) {
	checks := []struct {
		err      error
		contains string
	}{
		{&MissingKeyError{DeepL}, "DeepL needs an API key."},
		{&HTTPError{401, "bad key"}, "HTTP 401: bad key"},
		{&HTTPError{503, ""}, "(HTTP 503)"},
		{&HTTPError{401, ""}, "API key"},
		{&HTTPError{404, ""}, "base URL"},
		{&HTTPError{413, ""}, "too long"},
		{&NotAStreamError{[]byte("<html>")}, "base URL"},
	}
	for _, c := range checks {
		if !strings.Contains(c.err.Error(), c.contains) {
			t.Errorf("%q lacks %q", c.err.Error(), c.contains)
		}
	}
	if got := (&HTTPError{418, ""}).Error(); got != "HTTP 418" {
		t.Error(got)
	}
	if got := (&NotAStreamError{[]byte(`{"error":{"message":"Not found"}}`)}).Error(); got != "Not found" {
		t.Error(got)
	}
}

func TestNeedsSettings(t *testing.T) {
	yes := []struct {
		err  error
		kind Kind
	}{
		{&MissingKeyError{OpenAI}, OpenAI}, {&HTTPError{401, ""}, Claude},
		{&HTTPError{404, ""}, OpenAI}, {&NotAStreamError{}, OpenAI},
	}
	for _, c := range yes {
		if !NeedsSettings(c.err, c.kind) {
			t.Errorf("%v should need settings", c.err)
		}
	}
	if NeedsSettings(&HTTPError{500, ""}, OpenAI) || NeedsSettings(ErrTimedOut, OpenAI) || NeedsSettings(&HTTPError{404, ""}, Google) {
		t.Error("should not need settings")
	}
}

// mock serves the behaviours of scripts/mock-service.py.
func mock(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := strings.TrimSuffix(r.URL.Path, "/chat/completions")
		chunk := func(delta string, finish any) {
			fmt.Fprintf(w, "data: {\"choices\":[{\"delta\":%s,\"finish_reason\":%v}]}\n\n", delta, finish)
		}
		switch path {
		case "/fail":
			w.WriteHeader(401)
			w.Write([]byte(`{"error":{"message":"Incorrect API key"}}`))
			return
		case "/plain":
			w.Write([]byte(`{"choices":[{"message":{"content":"你好"},"finish_reason":"stop"}]}`))
			return
		case "/html":
			w.Write([]byte("<html>nope</html>"))
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		switch path {
		case "/v1":
			for _, s := range []string{"你", "好"} {
				chunk(`{"content":"`+s+`"}`, "null")
			}
		case "/think":
			chunk(`{"reasoning_content":"Hmm"}`, "null")
			chunk(`{"reasoning_content":"more"}`, "null")
			chunk(`{"content":"好"}`, "null")
		case "/length":
			chunk(`{"content":"半"}`, `"length"`)
		case "/empty":
		}
		w.Write([]byte("data: [DONE]\n\n"))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func run(t *testing.T, base string) ([]Chunk, error) {
	var got []Chunk
	err := Translate(context.Background(), OpenAI, Config{BaseURL: base, APIKey: "x", Model: "m"},
		"hello", lang.English, lang.ChineseSimplified, func(c Chunk) { got = append(got, c) })
	return got, err
}

func TestOpenAIStreams(t *testing.T) {
	srv := mock(t)
	got, err := run(t, srv.URL+"/v1")
	if err != nil || len(got) != 2 || got[0].Text+got[1].Text != "你好" {
		t.Errorf("got %v %v", got, err)
	}
	got, err = run(t, srv.URL+"/think")
	if err != nil || len(got) != 2 || !got[0].Thinking || got[1].Text != "好" {
		t.Errorf("think: %v %v", got, err)
	}
	got, err = run(t, srv.URL+"/plain")
	if err != nil || len(got) != 1 || got[0].Text != "你好" {
		t.Errorf("plain: %v %v", got, err)
	}
	got, err = run(t, srv.URL+"/length")
	if !errors.Is(err, ErrTruncated) || len(got) != 1 {
		t.Errorf("length: %v %v", got, err)
	}
	got, err = run(t, srv.URL+"/empty")
	if err != nil || len(got) != 0 {
		t.Errorf("empty: %v %v", got, err)
	}
	_, err = run(t, srv.URL+"/fail")
	var he *HTTPError
	if !errors.As(err, &he) || he.Code != 401 || he.Message != "Incorrect API key" {
		t.Errorf("fail: %v", err)
	}
	_, err = run(t, srv.URL+"/html")
	var ns *NotAStreamError
	if !errors.As(err, &ns) || !NeedsSettings(err, OpenAI) {
		t.Errorf("html: %v", err)
	}
	err = Translate(context.Background(), OpenAI, Config{BaseURL: srv.URL}, "x", "", lang.English, func(Chunk) {})
	var mk *MissingKeyError
	if !errors.As(err, &mk) {
		t.Errorf("missing key: %v", err)
	}
}

func TestClaudeStreams(t *testing.T) {
	var body string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b := make([]byte, 4096)
		n, _ := r.Body.Read(b)
		body = string(b[:n])
		if r.URL.Path != "/v1/messages" || r.Header.Get("x-api-key") != "k" {
			w.WriteHeader(404)
			return
		}
		w.Write([]byte("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Bon\"}}\n\n" +
			"data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"jour\"}}\n\n" +
			"data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n"))
	}))
	defer srv.Close()
	var got string
	err := Translate(context.Background(), Claude, Config{BaseURL: srv.URL, APIKey: "k", Model: "claude-opus-5-5"},
		"Hello", lang.English, lang.French, func(c Chunk) { got += c.Text })
	if err != nil || got != "Bonjour" {
		t.Errorf("got %q %v", got, err)
	}
	if !strings.Contains(body, `"effort":"low"`) {
		t.Errorf("Claude 5 should run at low effort: %s", body)
	}
}
