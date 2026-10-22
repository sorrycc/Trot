package mon

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

// failingTransport fails its first fails requests with err, then answers
// 200 with the body it was sent.
type failingTransport struct {
	fails int
	err   error
	tries int
	sent  []string
}

func (t *failingTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	t.tries++
	var body []byte
	if req.Body != nil {
		body, _ = io.ReadAll(req.Body)
		req.Body.Close()
	}
	t.sent = append(t.sent, string(body))
	if t.tries <= t.fails {
		return nil, t.err
	}
	return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{}`)), Header: http.Header{}}, nil
}

func shortRetries(t *testing.T) {
	old := retryWaits
	retryWaits = []time.Duration{time.Millisecond, time.Millisecond}
	t.Cleanup(func() { retryWaits = old })
}

func TestDoRetriesConnectionNotEstablished(t *testing.T) {
	shortRetries(t)
	ft := &failingTransport{fails: 2, err: errors.New("http2: client conn could not be established")}
	c := &Client{BaseURL: "https://mon.test", HTTPClient: &http.Client{Transport: ft}}
	if err := c.do(context.Background(), "POST", "/api/v1/device/code", url.Values{"client_id": {"ikaga"}}, nil); err != nil {
		t.Fatal(err)
	}
	if ft.tries != 3 {
		t.Fatalf("tries = %d, want 3", ft.tries)
	}
	for i, b := range ft.sent {
		if b != "client_id=ikaga" {
			t.Errorf("try %d sent %q", i, b)
		}
	}
}

func TestDoGivesUpAfterRetries(t *testing.T) {
	shortRetries(t)
	ft := &failingTransport{fails: 10, err: errors.New("http2: client conn could not be established")}
	c := &Client{BaseURL: "https://mon.test", HTTPClient: &http.Client{Transport: ft}}
	if err := c.do(context.Background(), "POST", "/x", url.Values{}, nil); err == nil {
		t.Fatal("no error")
	}
	if ft.tries != 1+len(retryWaits) {
		t.Fatalf("tries = %d", ft.tries)
	}
}

func TestDoDoesNotRetryWhatMayHaveBeenSent(t *testing.T) {
	shortRetries(t)
	ft := &failingTransport{fails: 1, err: io.ErrUnexpectedEOF}
	c := &Client{BaseURL: "https://mon.test", HTTPClient: &http.Client{Transport: ft}}
	if err := c.do(context.Background(), "POST", "/x", map[string]string{"a": "b"}, nil); err == nil {
		t.Fatal("no error")
	}
	if ft.tries != 1 {
		t.Fatalf("tries = %d, want 1", ft.tries)
	}
}

func TestNotSentDialError(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	_, err = http.Get("http://" + addr)
	if err == nil || !notSent(err) {
		t.Fatalf("notSent(%v) = false", err)
	}
}
