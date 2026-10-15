//go:build darwin

package mac

import (
	"encoding/json"
	"strings"
	"time"
)

// Representation is one type of a pasteboard item and its data.
type Representation struct {
	Type string
	Data []byte
}

// Snapshot is the general pasteboard's items, each its representations.
type Snapshot [][]Representation

func generalPasteboard() id { return send(class("NSPasteboard"), "generalPasteboard") }

// ChangeCount is the general pasteboard's change count, which goes up with
// every write.
func ChangeCount() int {
	var n int
	withPool(func() { n = sendInt(generalPasteboard(), "changeCount") })
	return n
}

// PasteboardString is the general pasteboard's text, trimmed.
func PasteboardString() string {
	var s string
	withPool(func() {
		s = goString(send(generalPasteboard(), "stringForType:", uintptr(nsString("public.utf8-plain-text"))))
	})
	return strings.TrimSpace(s)
}

// CopiedFromEmptySelection reports whether VS Code or Cursor copied the
// current line because nothing was selected, as they say in their editor
// data.
func CopiedFromEmptySelection() bool {
	var data []byte
	withPool(func() {
		data = goBytes(send(generalPasteboard(), "dataForType:", uintptr(nsString("vscode-editor-data"))))
	})
	var v struct {
		IsFromEmptySelection bool `json:"isFromEmptySelection"`
	}
	return len(data) > 0 && json.Unmarshal(data, &v) == nil && v.IsFromEmptySelection
}

// TakeSnapshot copies the pasteboard's items as data, skipping promised
// and dynamic types. Reading lazy types makes their app render them, which
// can take a while, so it has a budget: ok is false when the contents are
// too large or slow to copy, and the clipboard won't be restored.
func TakeSnapshot() (snap Snapshot, ok bool) {
	ok = true
	withPool(func() {
		start := time.Now()
		total := 0
		for _, item := range arrayItems(send(generalPasteboard(), "pasteboardItems")) {
			var entry []Representation
			for _, t := range arrayItems(send(item, "types")) {
				name := goString(t)
				if strings.Contains(name, "promise") || strings.HasPrefix(name, "dyn.") {
					continue
				}
				data := send(item, "dataForType:", uintptr(t))
				if data == 0 {
					continue
				}
				b := goBytes(data)
				total += len(b)
				if total > 32<<20 || time.Since(start) > 300*time.Millisecond {
					snap, ok = nil, false
					return
				}
				entry = append(entry, Representation{name, b})
			}
			snap = append(snap, entry)
		}
	})
	return snap, ok
}

// Restore puts a snapshot back on the general pasteboard.
func Restore(snap Snapshot) {
	withPool(func() {
		pb := generalPasteboard()
		send(pb, "clearContents")
		var items []id
		for _, entry := range snap {
			if len(entry) == 0 {
				continue
			}
			item := send(send(send(class("NSPasteboardItem"), "alloc"), "init"), "autorelease")
			for _, r := range entry {
				send(item, "setData:forType:", uintptr(nsData(r.Data)), uintptr(nsString(r.Type)))
			}
			items = append(items, item)
		}
		if len(items) > 0 {
			send(pb, "writeObjects:", uintptr(nsArray(items...)))
		}
	})
}
