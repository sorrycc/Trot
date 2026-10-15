package settings

import (
	"bytes"
	"encoding/xml"
	"io"
	"os/exec"
	"strings"

	"trot/internal/shortcut"
)

// Legacy domains of Trot's user defaults: the Swift app's before 0.5, and
// its id before 0.3.1.
var legacyDomains = []string{"dev.sorrycc.trot.app", "dev.sorrycc.trot"}

// importedKeys are the user defaults Trot before 0.5 kept.
func importedKey(key string) bool {
	switch key {
	case "firstLanguage", "secondLanguage", "service", "welcomed", "accessibilityPrompted":
		return true
	}
	return strings.HasPrefix(key, "service.") || strings.HasPrefix(key, "shortcut.")
}

// ImportLegacy copies the settings of the Swift app's user defaults, once:
// only while the settings file doesn't exist yet. Shortcuts move to
// accelerators.
func (s *Settings) ImportLegacy() bool {
	if s.Exists() {
		return false
	}
	for _, domain := range legacyDomains {
		out, err := exec.Command("/usr/bin/defaults", "export", domain, "-").Output()
		if err != nil {
			continue
		}
		values := parsePlist(out)
		imported := 0
		s.mu.Lock()
		for k, v := range values {
			if !importedKey(k) {
				continue
			}
			if strings.HasPrefix(k, "shortcut.") && v != "" {
				sc, ok := shortcut.ParseLegacy(v)
				if !ok {
					continue
				}
				v = sc.Accelerator()
			}
			s.values[k] = v
			imported++
		}
		if imported > 0 {
			s.saveLocked()
		}
		s.mu.Unlock()
		if imported > 0 {
			return true
		}
	}
	return false
}

// parsePlist reads the top-level dictionary of an XML property list, its
// strings, booleans and numbers as strings.
func parsePlist(data []byte) map[string]string {
	out := map[string]string{}
	d := xml.NewDecoder(bytes.NewReader(data))
	d.Strict = false
	depth := 0
	key := ""
	for {
		tok, err := d.Token()
		if err == io.EOF || err != nil {
			return out
		}
		switch t := tok.(type) {
		case xml.StartElement:
			depth++
			// The plist element is 1, its dict 2, and the values 3.
			if depth != 3 {
				continue
			}
			switch t.Name.Local {
			case "key":
				var k string
				d.DecodeElement(&k, &t)
				key = k
				depth--
			case "string", "integer", "real":
				var v string
				d.DecodeElement(&v, &t)
				if key != "" {
					out[key] = v
				}
				key = ""
				depth--
			case "true":
				if key != "" {
					out[key] = "1"
				}
				key = ""
			case "false":
				key = ""
			default:
				key = ""
			}
		case xml.EndElement:
			depth--
		}
	}
}
