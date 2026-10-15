//go:build darwin

package mac

import (
	"strings"
	"sync"
	"unsafe"

	"github.com/ebitengine/purego"
)

var (
	axIsTrusted            func() bool
	axIsTrustedWithOptions func(options uintptr) bool
	axCreateSystemWide     func() uintptr
	axCreateApplication    func(pid int32) uintptr
	axCopyAttributeValue   func(element uintptr, attribute uintptr, value *uintptr) int32
	axSetAttributeValue    func(element uintptr, attribute uintptr, value uintptr) int32
	axSetMessagingTimeout  func(element uintptr, seconds float32) int32
	axElementTypeID        func() uintptr
	cfBooleanTrue          uintptr
)

func loadAX() {
	purego.RegisterLibFunc(&axIsTrusted, libAX, "AXIsProcessTrusted")
	purego.RegisterLibFunc(&axIsTrustedWithOptions, libAX, "AXIsProcessTrustedWithOptions")
	purego.RegisterLibFunc(&axCreateSystemWide, libAX, "AXUIElementCreateSystemWide")
	purego.RegisterLibFunc(&axCreateApplication, libAX, "AXUIElementCreateApplication")
	purego.RegisterLibFunc(&axCopyAttributeValue, libAX, "AXUIElementCopyAttributeValue")
	purego.RegisterLibFunc(&axSetAttributeValue, libAX, "AXUIElementSetAttributeValue")
	purego.RegisterLibFunc(&axSetMessagingTimeout, libAX, "AXUIElementSetMessagingTimeout")
	purego.RegisterLibFunc(&axElementTypeID, libAX, "AXUIElementGetTypeID")
	p := mustDlsym(libCF, "kCFBooleanTrue")
	cfBooleanTrue = **(**uintptr)(unsafe.Pointer(&p))
}

// axTimeout is how long an app has to answer: Accessibility calls block
// until it does.
const axTimeout = 0.3

// IsTrusted reports whether Trot has the Accessibility permission, which
// reading another app's selection needs.
func IsTrusted() bool {
	load()
	return axIsTrusted()
}

// PromptAccessibility asks macOS to show its permission prompt.
func PromptAccessibility() {
	withPool(func() {
		key := nsString("AXTrustedCheckOptionPrompt")
		yes := send(class("NSNumber"), "numberWithBool:", 1)
		dict := send(class("NSDictionary"), "dictionaryWithObject:forKey:", uintptr(yes), uintptr(key))
		axIsTrustedWithOptions(uintptr(dict))
	})
}

// AXAnswer is what Accessibility said about the focused element's
// selection.
type AXAnswer int

const (
	// AXUnavailable: the element exposes no selection, as web views and
	// Electron apps don't.
	AXUnavailable AXAnswer = iota
	// AXEmpty: it has a selection attribute and it's empty.
	AXEmpty
	// AXText: it has selected text.
	AXText
)

// copyAttribute returns an attribute's value, owned by the caller, or 0.
func copyAttribute(element uintptr, name string) uintptr {
	var value uintptr
	if axCopyAttributeValue(element, uintptr(nsString(name)), &value) != 0 {
		return 0
	}
	return value
}

func isElement(ref uintptr) bool { return ref != 0 && cfTypeID(ref) == axElementTypeID() }

// SelectedText reads the focused element's selected text through
// Accessibility, trimmed.
func SelectedText() (AXAnswer, string) {
	answer, text := AXUnavailable, ""
	withPool(func() {
		system := axCreateSystemWide()
		defer cfRelease(system)
		axSetMessagingTimeout(system, axTimeout)
		focused := copyAttribute(system, "AXFocusedUIElement")
		if focused == 0 {
			return
		}
		defer cfRelease(focused)
		if !isElement(focused) {
			return
		}
		axSetMessagingTimeout(focused, axTimeout)
		value := copyAttribute(focused, "AXSelectedText")
		if value == 0 {
			return
		}
		defer cfRelease(value)
		if isKind(id(value), "NSString") {
			text = strings.TrimSpace(goString(id(value)))
		}
		if text == "" {
			answer = AXEmpty
		} else {
			answer = AXText
		}
	})
	return answer, text
}

// EnableManualAccessibility asks an Electron app to build its
// accessibility tree, which it does only when asked.
func EnableManualAccessibility(pid int) {
	withPool(func() {
		app := axCreateApplication(int32(pid))
		defer cfRelease(app)
		axSetMessagingTimeout(app, axTimeout)
		axSetAttributeValue(app, uintptr(nsString("AXManualAccessibility")), cfBooleanTrue)
	})
}

var (
	copyItemsMu sync.Mutex
	// copyItems are each app's Edit > Copy item, found once and retained:
	// asking it alone whether it is enabled is one call where walking the
	// menus is dozens.
	copyItems = map[int]uintptr{}
)

// CopyMenuEnabled reports whether the app's ⌘C menu item is enabled,
// found by its key equivalent so menu titles in any language work. ok is
// false when the menu can't be read.
func CopyMenuEnabled(pid int) (enabled, ok bool) {
	withPool(func() {
		copyItemsMu.Lock()
		item := copyItems[pid]
		copyItemsMu.Unlock()
		if item != 0 {
			if e, found := boolAttribute(item, "AXEnabled"); found {
				enabled, ok = e, true
				return
			}
		}
		item = findCopyItem(pid)
		if item == 0 {
			return
		}
		copyItemsMu.Lock()
		if old := copyItems[pid]; old != 0 {
			cfRelease(old)
		}
		copyItems[pid] = item
		copyItemsMu.Unlock()
		e, found := boolAttribute(item, "AXEnabled")
		enabled, ok = e || !found, true
	})
	return enabled, ok
}

func boolAttribute(element uintptr, name string) (bool, bool) {
	v := copyAttribute(element, name)
	if v == 0 {
		return false, false
	}
	defer cfRelease(v)
	if !isKind(id(v), "NSNumber") {
		return false, false
	}
	return sendBool(id(v), "boolValue"), true
}

// children returns an element's children, which stay alive as long as
// the array: callers release the array after use.
func children(parent uintptr) (arr uintptr, items []uintptr) {
	arr = copyAttribute(parent, "AXChildren")
	if arr == 0 {
		return 0, nil
	}
	if !isKind(id(arr), "NSArray") {
		cfRelease(arr)
		return 0, nil
	}
	for _, it := range arrayItems(id(arr)) {
		if isElement(uintptr(it)) {
			items = append(items, uintptr(it))
		}
	}
	return arr, items
}

// findCopyItem returns the retained ⌘C item of an app's menu bar, or 0.
func findCopyItem(pid int) uintptr {
	app := axCreateApplication(int32(pid))
	defer cfRelease(app)
	axSetMessagingTimeout(app, axTimeout)
	bar := copyAttribute(app, "AXMenuBar")
	if bar == 0 {
		return 0
	}
	defer cfRelease(bar)
	if !isElement(bar) {
		return 0
	}
	arr, menus := children(bar)
	if arr == 0 {
		return 0
	}
	defer cfRelease(arr)
	// Edit is nearly always the third menu, after the app menu and File,
	// so it goes first.
	if len(menus) > 0 {
		menus = menus[1:]
	}
	if len(menus) > 1 {
		menus[0], menus[1] = menus[1], menus[0]
	}
	for _, menu := range menus {
		subArr, submenus := children(menu)
		for _, submenu := range submenus {
			itemArr, items := children(submenu)
			for _, item := range items {
				if menuItemIsCopy(item) {
					cfRetain(item)
					cfRelease(itemArr)
					cfRelease(subArr)
					return item
				}
			}
			if itemArr != 0 {
				cfRelease(itemArr)
			}
		}
		if subArr != 0 {
			cfRelease(subArr)
		}
	}
	return 0
}

func menuItemIsCopy(item uintptr) bool {
	key := copyAttribute(item, "AXMenuItemCmdChar")
	if key == 0 {
		return false
	}
	defer cfRelease(key)
	if !isKind(id(key), "NSString") || !strings.EqualFold(goString(id(key)), "c") {
		return false
	}
	mods := copyAttribute(item, "AXMenuItemCmdModifiers")
	if mods == 0 {
		return true
	}
	defer cfRelease(mods)
	return !isKind(id(mods), "NSNumber") || sendInt(id(mods), "intValue") == 0
}

// Frontmost returns the frontmost app's process ID and bundle identifier.
func Frontmost() (pid int, bundle string) {
	withPool(func() {
		app := send(send(class("NSWorkspace"), "sharedWorkspace"), "frontmostApplication")
		if app == 0 {
			return
		}
		pid = int(int32(sendInt(app, "processIdentifier")))
		bundle = goString(send(app, "bundleIdentifier"))
	})
	return pid, bundle
}
