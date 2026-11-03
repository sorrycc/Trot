package service

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"trot/internal/lang"
)

func TestIndexMetadata(t *testing.T) {
	if IndexTranslate.NeedsKey() || IndexTranslate.SignsIn() || !IndexTranslate.HasBaseURL() || !IndexTranslate.HasModel() {
		t.Fatal("local inference requires a configurable URL/model, not a key or sign-in")
	}
	if IndexTranslate.DefaultBaseURL() != "http://127.0.0.1:8000/v1" || IndexTranslate.DefaultModel() != "IndexTeam/Index-Translate-9B" {
		t.Fatal("unexpected defaults")
	}
	if !reflect.DeepEqual(Kinds, []Kind{Mon, OpenAI, Claude, DeepL, Google, IndexTranslate}) {
		t.Fatal("existing shortcuts must not move")
	}
}

func TestIndexRequest(t *testing.T) {
	for _, key := range []string{"", "local-secret"} {
		t.Run(key, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != "POST" || r.URL.Path != "/v1/chat/completions" {
					t.Errorf("request %s %s", r.Method, r.URL.Path)
				}
				wantAuth := ""
				if key != "" {
					wantAuth = "Bearer " + key
				}
				if r.Header.Get("Authorization") != wantAuth {
					t.Errorf("authorization: %q", r.Header.Get("Authorization"))
				}
				if r.Header.Get("Content-Type") != "application/json" {
					t.Error("content type")
				}
				var body map[string]any
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Error(err)
				}
				if body["model"] != "custom-alias" || body["stream"] != false || body["temperature"] != float64(0) || body["max_tokens"] != float64(1024) {
					t.Errorf("request settings: %v", body)
				}
				wantMessages := []any{map[string]any{"role": "user", "content": "请将以下English文本翻译为Simplified Chinese，直接输出翻译结果，不要进行任何解释。\n\nHello"}}
				if !reflect.DeepEqual(body["messages"], wantMessages) {
					t.Errorf("messages: %v", body["messages"])
				}
				if !reflect.DeepEqual(body["chat_template_kwargs"], map[string]any{"enable_thinking": false}) {
					t.Error("thinking must be disabled")
				}
				w.Header().Set("Content-Type", "application/json")
				content := "你好"
				if key != "" {
					content = "<think>private reasoning</think>\n你好"
				}
				json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"message": map[string]string{"content": content}, "finish_reason": "stop"}}})
			}))
			defer server.Close()
			var chunks []Chunk
			err := Translate(context.Background(), IndexTranslate, Config{BaseURL: server.URL + "/v1", Model: "custom-alias", APIKey: key}, "Hello", lang.English, lang.ChineseSimplified, func(c Chunk) { chunks = append(chunks, c) })
			if err != nil || !reflect.DeepEqual(chunks, []Chunk{{Text: "你好"}}) {
				t.Fatalf("chunks %v, error %v", chunks, err)
			}
		})
	}
	if got := indexPrompt("Hi", "", lang.Japanese); !strings.HasPrefix(got, "请将以下文本翻译为Japanese") {
		t.Fatal(got)
	}
}

func TestIndexResponseContent(t *testing.T) {
	for _, tc := range []struct {
		name, content, want string
	}{
		{"closing tag in text", "使用 </think> 结束推理块，然后输出答案", "使用 </think> 结束推理块，然后输出答案"},
		{"opening tag in text", "使用 <think> 开始推理块", "使用 <think> 开始推理块"},
		{"inline code", "保留 `<think>` 和 `</think>` 标签", "保留 `<think>` 和 `</think>` 标签"},
		{"code span at start", "`<think>` 与 `</think>`", "`<think>` 与 `</think>`"},
		{"code fence at start", "```html\n<think>示例</think>\n```", "```html\n<think>示例</think>\n```"},
		{"unclosed literal after text", "translation<think>secret", "translation<think>secret"},
		{"literal after reasoning", "<think>private reasoning</think>使用 </think> 结束推理块", "使用 </think> 结束推理块"},
		{"opening literal after reasoning", "<think>private reasoning</think>使用 <think> 开始推理块", "使用 <think> 开始推理块"},
		{"consecutive reasoning", " <think>first</think>\n<think>second</think>\n你好 ", "你好"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{
					"message": map[string]string{"content": tc.content}, "finish_reason": "stop",
				}}})
			}))
			defer server.Close()
			var result strings.Builder
			err := Translate(context.Background(), IndexTranslate, Config{BaseURL: server.URL}, "text", lang.English, lang.ChineseSimplified, func(c Chunk) { result.WriteString(c.Text) })
			if err != nil || result.String() != tc.want {
				t.Fatalf("got %q, error %v; want %q", result.String(), err, tc.want)
			}
		})
	}
}

func TestIndexResponseErrors(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		want       error
	}{
		{"malformed", "not JSON", ErrInvalidResponse},
		{"empty choices", `{"choices":[]}`, ErrInvalidResponse},
		{"empty text", `{"choices":[{"message":{"content":" "}}]}`, ErrInvalidResponse},
		{"unfinished thought", `{"choices":[{"message":{"content":"<think>secret"}}]}`, ErrInvalidResponse},
		{"unfinished thought after completed", `{"choices":[{"message":{"content":"<think>done</think><think>secret"}}]}`, ErrInvalidResponse},
		{"truncated", `{"choices":[{"message":{"content":"partial"},"finish_reason":"length"}]}`, ErrTruncated},
		{"filtered", `{"choices":[{"message":{},"finish_reason":"content_filter"}]}`, nil},
		{"refusal", `{"choices":[{"message":{"refusal":"blocked"}}]}`, nil},
		{"server error", `{"error":{"message":"unknown model"}}`, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(tc.body)) }))
			defer server.Close()
			err := translateIndex(context.Background(), Config{BaseURL: server.URL}, "Hello", "", lang.Japanese, func(Chunk) { t.Error("must not emit failed output") })
			if tc.want != nil {
				if !errors.Is(err, tc.want) {
					t.Fatalf("got %v, want %v", err, tc.want)
				}
			} else {
				var refusal *RefusedError
				if !errors.As(err, &refusal) {
					t.Fatalf("expected refusal, got %v", err)
				}
			}
		})
	}
}

func TestIndexDoesNotFollowRedirect(t *testing.T) {
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Error("must not forward text or credentials") }))
	defer target.Close()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL, http.StatusTemporaryRedirect)
	}))
	defer server.Close()
	err := translateIndex(context.Background(), Config{BaseURL: server.URL, APIKey: "secret"}, "private", "", lang.Japanese, func(Chunk) { t.Error("unexpected output") })
	var he *HTTPError
	if !errors.As(err, &he) || he.Code != http.StatusTemporaryRedirect {
		t.Fatal(err)
	}
}

func TestIndexCancellation(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		close(started)
		select {
		case <-r.Context().Done():
		case <-release:
		}
	}))
	defer server.Close()
	defer close(release)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		done <- translateIndex(ctx, Config{BaseURL: server.URL}, "Hello", "", lang.Japanese, func(Chunk) {})
	}()
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("request did not start")
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("cancellation stalled")
	}
}
