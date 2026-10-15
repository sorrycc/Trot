//go:build darwin

package mac

import "github.com/ebitengine/purego"

var (
	cgEventSourceCreate        func(state int32) uintptr
	cgEventCreateKeyboardEvent func(source uintptr, key uint16, down bool) uintptr
	cgEventSetFlags            func(event uintptr, flags uint64)
	cgEventPost                func(tap uint32, event uintptr)
	cgPreflightScreenCapture   func() bool
	cgRequestScreenCapture     func() bool
)

func loadCG() {
	purego.RegisterLibFunc(&cgEventSourceCreate, libCG, "CGEventSourceCreate")
	purego.RegisterLibFunc(&cgEventCreateKeyboardEvent, libCG, "CGEventCreateKeyboardEvent")
	purego.RegisterLibFunc(&cgEventSetFlags, libCG, "CGEventSetFlags")
	purego.RegisterLibFunc(&cgEventPost, libCG, "CGEventPost")
	purego.RegisterLibFunc(&cgPreflightScreenCapture, libCG, "CGPreflightScreenCaptureAccess")
	purego.RegisterLibFunc(&cgRequestScreenCapture, libCG, "CGRequestScreenCaptureAccess")
}

const (
	combinedSessionState = 0
	hidEventTap          = 0
	maskCommand          = 1 << 20
	keyC                 = 8
)

// PostCopy sends ⌘C to the frontmost app. Only Command goes in the flags,
// so the hotkey's own modifiers, likely still held, don't ride along.
func PostCopy() {
	load()
	source := cgEventSourceCreate(combinedSessionState)
	if source != 0 {
		defer cfRelease(source)
	}
	down := cgEventCreateKeyboardEvent(source, keyC, true)
	up := cgEventCreateKeyboardEvent(source, keyC, false)
	if down == 0 || up == 0 {
		return
	}
	defer cfRelease(down)
	defer cfRelease(up)
	cgEventSetFlags(down, maskCommand)
	cgEventSetFlags(up, maskCommand)
	cgEventPost(hidEventTap, down)
	cgEventPost(hidEventTap, up)
}

// ScreenCaptureAllowed reports whether Screen Recording is granted. macOS
// answers for the time the app was opened, so a grant shows after Trot is
// opened again.
func ScreenCaptureAllowed() bool {
	load()
	return cgPreflightScreenCapture()
}

// RequestScreenCapture asks macOS to show its permission prompt, which
// also lists Trot under Screen Recording in System Settings.
func RequestScreenCapture() {
	load()
	cgRequestScreenCapture()
}

// Settings pages of the privacy permissions, for mygo.Shell.OpenExternal.
const (
	AccessibilitySettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
	ScreenCaptureSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
)
