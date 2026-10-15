package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"unicode/utf8"
)

// MissingKeyError is a service used without its API key.
type MissingKeyError struct{ Kind Kind }

func (e *MissingKeyError) Error() string { return e.Kind.DisplayName() + " needs an API key." }

// BadURLError is a base URL that isn't one.
type BadURLError struct{ URL string }

func (e *BadURLError) Error() string {
	return fmt.Sprintf("%q is not a valid URL. Check the base URL in Settings.", e.URL)
}

// HTTPError is a reply with a status other than 2xx, and the service's
// message.
type HTTPError struct {
	Code    int
	Message string
}

func (e *HTTPError) Error() string {
	if e.Message == "" {
		return DescribeStatus(e.Code)
	}
	return fmt.Sprintf("HTTP %d: %s", e.Code, e.Message)
}

// RefusedError is a service declining to translate.
type RefusedError struct{ Reason string }

func (e *RefusedError) Error() string {
	if e.Reason == "" {
		return "The service declined to translate this."
	}
	return e.Reason
}

// NotAStreamError is a 200 reply that wasn't an event stream, with its
// body.
type NotAStreamError struct{ Body []byte }

func (e *NotAStreamError) Error() string {
	if m := ErrorMessage(e.Body); m != "" {
		return m
	}
	return "The service replied with something other than a translation. Check the base URL."
}

var (
	// ErrInvalidResponse is a reply Trot can't read.
	ErrInvalidResponse = errors.New("The service sent a reply Trot can't read.")
	// ErrTruncated is a translation the service stopped at its output limit.
	ErrTruncated = errors.New("The translation was cut off: the text is too long for one request. Try a shorter selection.")
	// ErrTimedOut is a service that went quiet for too long.
	ErrTimedOut = errors.New("The request timed out.")
)

// DescribeStatus is a sentence for a status code that came with no
// message of its own.
func DescribeStatus(code int) string {
	switch {
	case code == 401 || code == 403:
		return fmt.Sprintf("The API key was rejected (HTTP %d).", code)
	case code == 404:
		return "Not found (HTTP 404). Check the base URL and the model."
	case code == 413:
		return "The text is too long for this service (HTTP 413)."
	case code == 429:
		return "Too many requests (HTTP 429). Try again in a moment."
	case code == 456:
		return "The DeepL quota for this key is used up (HTTP 456)."
	case code >= 500 && code <= 599:
		return fmt.Sprintf("The service is having trouble (HTTP %d). Try again in a moment.", code)
	}
	return fmt.Sprintf("HTTP %d", code)
}

// ErrorMessage is the message in a JSON error body, in the shapes OpenAI,
// Anthropic and DeepL use, else the body itself when it's short plain
// text. Markup, as a wrong base URL answers with, is never a message.
func ErrorMessage(body []byte) string {
	var v map[string]any
	if json.Unmarshal(body, &v) == nil {
		if e, ok := v["error"].(map[string]any); ok {
			if m, ok := e["message"].(string); ok {
				return m
			}
		}
		if m, ok := v["message"].(string); ok {
			return m
		}
		if e, ok := v["error"].(string); ok {
			return e
		}
	}
	text := strings.TrimSpace(string(body))
	if utf8.RuneCountInString(text) > 200 || strings.HasPrefix(text, "<") || strings.HasPrefix(text, "{") {
		return ""
	}
	return text
}

// NeedsSettings reports whether Settings can fix the error: a missing or
// rejected key, a wrong base URL. Google has nothing to set.
func NeedsSettings(err error, k Kind) bool {
	if k == Google {
		return false
	}
	var mk *MissingKeyError
	var bu *BadURLError
	var ns *NotAStreamError
	var he *HTTPError
	switch {
	case errors.As(err, &mk), errors.As(err, &bu), errors.As(err, &ns):
		return true
	case errors.As(err, &he):
		return he.Code == 401 || he.Code == 403 || he.Code == 404
	}
	return false
}

// Describe is an error as the panel says it: network failures in a
// sentence rather than Go's words.
func Describe(err error) string {
	var ne net.Error
	var dns *net.DNSError
	var op *net.OpError
	switch {
	case errors.Is(err, ErrTimedOut), errors.Is(err, context.DeadlineExceeded), errors.As(err, &ne) && ne.Timeout():
		return ErrTimedOut.Error()
	case errors.As(err, &dns):
		return "A server with the specified hostname could not be found."
	case errors.As(err, &op) && op.Op == "dial":
		return "Could not connect to the server."
	}
	return err.Error()
}
