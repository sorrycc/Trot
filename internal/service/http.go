package service

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

const (
	// idleTimeout is how long a reply may go without data.
	idleTimeout = 30 * time.Second
	// totalTimeout caps the whole transfer.
	totalTimeout = 3 * time.Minute
)

var client = &http.Client{
	Transport: &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		ResponseHeaderTimeout: idleTimeout,
		IdleConnTimeout:       90 * time.Second,
		ForceAttemptHTTP2:     true,
		TLSHandshakeTimeout:   10 * time.Second,
	},
}

// Preconnect opens the connection to the service's host ahead of the
// request, so the DNS, TCP and TLS round trips overlap with reading the
// selection instead of adding to the wait for the first word. The reply is
// ignored; the pooled connection is what matters.
func Preconnect(k Kind, c Config) {
	u, err := url.Parse(k.Host(c))
	if err != nil || u.Host == "" {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		req, err := http.NewRequestWithContext(ctx, http.MethodHead, u.String(), nil)
		if err != nil {
			return
		}
		if resp, err := client.Do(req); err == nil {
			io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
		}
	}()
}

// idleReader fails a read that waits longer than idleTimeout, by
// cancelling the request.
type idleReader struct {
	r     io.ReadCloser
	timer *time.Timer
	mu    sync.Mutex
	idle  bool
}

func newIdleReader(r io.ReadCloser, cancel context.CancelFunc) *idleReader {
	ir := &idleReader{r: r}
	ir.timer = time.AfterFunc(idleTimeout, func() {
		ir.mu.Lock()
		ir.idle = true
		ir.mu.Unlock()
		cancel()
	})
	return ir
}

func (r *idleReader) Read(p []byte) (int, error) {
	n, err := r.r.Read(p)
	r.timer.Reset(idleTimeout)
	if err != nil && err != io.EOF {
		r.mu.Lock()
		idle := r.idle
		r.mu.Unlock()
		if idle {
			return n, ErrTimedOut
		}
	}
	return n, err
}

func (r *idleReader) Close() error {
	r.timer.Stop()
	return r.r.Close()
}

// post sends body and returns the reply's body, which the caller closes
// and whose reads time out when the service goes quiet. A status other
// than 2xx is an HTTPError with the service's message.
func post(ctx context.Context, target string, headers map[string]string, body []byte, contentType string) (io.ReadCloser, error) {
	u, err := url.Parse(target)
	if err != nil || u.Scheme == "" || u.Host == "" {
		return nil, &BadURLError{target}
	}
	ctx, cancel := context.WithTimeout(ctx, totalTimeout)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, target, bytes.NewReader(body))
	if err != nil {
		cancel()
		return nil, &BadURLError{target}
	}
	req.Header.Set("Content-Type", contentType)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := client.Do(req)
	if err != nil {
		cancel()
		if ctx.Err() == context.DeadlineExceeded {
			return nil, ErrTimedOut
		}
		return nil, err
	}
	rc := &cancelCloser{newIdleReader(resp.Body, cancel), cancel}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		data, _ := io.ReadAll(io.LimitReader(rc, 16*1024))
		rc.Close()
		return nil, &HTTPError{resp.StatusCode, ErrorMessage(data)}
	}
	return rc, nil
}

type cancelCloser struct {
	io.ReadCloser
	cancel context.CancelFunc
}

func (c *cancelCloser) Close() error {
	err := c.ReadCloser.Close()
	c.cancel()
	return err
}

func postJSON(ctx context.Context, target string, headers map[string]string, body any) (io.ReadCloser, error) {
	data, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	return post(ctx, target, headers, data, "application/json")
}

// postForData sends body and returns the whole reply, for services that
// answer with one JSON document.
func postForData(ctx context.Context, target string, headers map[string]string, body []byte, contentType string) ([]byte, error) {
	rc, err := post(ctx, target, headers, body, contentType)
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	return io.ReadAll(rc)
}

// FormBody is fields as a form body, with every reserved character
// escaped, so a "+" in the text stays a plus.
func FormBody(fields [][2]string) []byte {
	parts := make([]string, len(fields))
	for i, f := range fields {
		parts[i] = f[0] + "=" + escape(f[1])
	}
	return []byte(strings.Join(parts, "&"))
}

func escape(s string) string {
	var b strings.Builder
	for _, c := range []byte(s) {
		if 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9' || strings.IndexByte("-._~", c) >= 0 {
			b.WriteByte(c)
		} else {
			b.WriteString("%" + strings.ToUpper(hex2(c)))
		}
	}
	return b.String()
}

func hex2(c byte) string {
	const digits = "0123456789abcdef"
	return string([]byte{digits[c>>4], digits[c&15]})
}

// events calls fn with the data: payload of each server-sent event, as a
// JSON object (empty when it isn't one), and stops at [DONE]. A reply with
// no events at all, such as plain JSON from a gateway that ignores
// stream, ends with a NotAStreamError holding the body.
func events(r io.Reader, fn func(event map[string]any) error) error {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 8<<20)
	sawEvent := false
	// Kept only until the first event shows this is a stream.
	var other bytes.Buffer
	for sc.Scan() {
		line := sc.Text()
		payload, ok := strings.CutPrefix(line, "data:")
		if !ok {
			if !sawEvent && other.Len() < 64*1024 {
				other.WriteString(line)
				other.WriteByte('\n')
			}
			continue
		}
		sawEvent = true
		payload = strings.TrimSpace(payload)
		if payload == "[DONE]" {
			return nil
		}
		if err := fn(ParseEvent(payload)); err != nil {
			return err
		}
	}
	if err := sc.Err(); err != nil {
		return err
	}
	if !sawEvent {
		return &NotAStreamError{other.Bytes()}
	}
	return nil
}

// ParseEvent is an event's payload as a JSON object, empty when it isn't
// one.
func ParseEvent(payload string) map[string]any {
	var v map[string]any
	if json.Unmarshal([]byte(payload), &v) != nil || v == nil {
		return map[string]any{}
	}
	return v
}
