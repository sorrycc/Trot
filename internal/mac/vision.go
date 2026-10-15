//go:build darwin

package mac

import (
	"errors"
	"unsafe"
)

// RecognizeText reads the lines of text in an image file with Vision, in
// Chinese, Japanese, Korean and English, in the order Vision gives them.
func RecognizeText(path string) (lines []string, err error) {
	withPool(func() {
		if !hasClass("VNRecognizeTextRequest") {
			err = errors.New("text recognition is unavailable on this Mac")
			return
		}
		url := send(class("NSURL"), "fileURLWithPath:", uintptr(nsString(path)))
		options := send(class("NSDictionary"), "dictionary")
		handler := send(send(send(class("VNImageRequestHandler"), "alloc"), "initWithURL:options:", uintptr(url), uintptr(options)), "autorelease")
		req := send(send(send(class("VNRecognizeTextRequest"), "alloc"), "init"), "autorelease")
		send(req, "setRecognitionLevel:", 0) // accurate
		send(req, "setUsesLanguageCorrection:", 1)
		if sendBool(req, "respondsToSelector:", uintptr(sel("setAutomaticallyDetectsLanguage:"))) {
			send(req, "setAutomaticallyDetectsLanguage:", 1)
		}
		var langs []id
		for _, l := range []string{"zh-Hans", "zh-Hant", "ja-JP", "ko-KR", "en-US"} {
			langs = append(langs, nsString(l))
		}
		send(req, "setRecognitionLanguages:", uintptr(nsArray(langs...)))
		var nsErr id
		if !sendBool(handler, "performRequests:error:", uintptr(nsArray(req)), uintptr(unsafe.Pointer(&nsErr))) {
			err = nsError(nsErr)
			if err == nil {
				err = errors.New("text recognition failed")
			}
			return
		}
		for _, obs := range arrayItems(send(req, "results")) {
			top := send(send(obs, "topCandidates:", 1), "firstObject")
			if top != 0 {
				lines = append(lines, goString(send(top, "string")))
			}
		}
	})
	return lines, err
}
