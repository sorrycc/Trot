//go:build darwin

// Package mac calls the macOS frameworks MyGo has no API for: Accessibility,
// synthesized keys, the pasteboard, Vision, speech and language
// recognition. Objective-C and C are driven through purego, without cgo, as
// MyGo drives AppKit.
package mac

import (
	"fmt"
	"runtime"
	"sync"
	"unsafe"

	"github.com/ebitengine/purego"
	"github.com/ebitengine/purego/objc"
)

type id = objc.ID

var (
	loadOnce sync.Once
	libObjC  uintptr
	libCF    uintptr
	libCG    uintptr
	libAX    uintptr

	msgSendAddr uintptr
	msgFloat    func(obj id, sel objc.SEL) float64
	msgSetFloat func(obj id, sel objc.SEL, v float32)

	poolPush func() uintptr
	poolPop  func(pool uintptr)

	cfRelease func(ref uintptr)
	cfRetain  func(ref uintptr) uintptr
	cfTypeID  func(ref uintptr) uintptr
)

func mustDlopen(path string) uintptr {
	h, err := purego.Dlopen(path, purego.RTLD_GLOBAL|purego.RTLD_NOW)
	if err != nil {
		panic(fmt.Sprintf("trot: cannot load %s: %v", path, err))
	}
	return h
}

func mustDlsym(lib uintptr, name string) uintptr {
	p, err := purego.Dlsym(lib, name)
	if err != nil {
		panic(fmt.Sprintf("trot: %v", err))
	}
	return p
}

// load opens the frameworks once, which also registers their classes.
func load() {
	loadOnce.Do(func() {
		libObjC = mustDlopen("/usr/lib/libobjc.A.dylib")
		mustDlopen("/System/Library/Frameworks/Foundation.framework/Foundation")
		mustDlopen("/System/Library/Frameworks/AppKit.framework/AppKit")
		libCF = mustDlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
		libCG = mustDlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
		libAX = mustDlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
		for _, fw := range []string{"Vision", "AVFoundation", "NaturalLanguage"} {
			_, _ = purego.Dlopen("/System/Library/Frameworks/"+fw+".framework/"+fw, purego.RTLD_GLOBAL|purego.RTLD_NOW)
		}
		msgSendAddr = mustDlsym(libObjC, "objc_msgSend")
		purego.RegisterFunc(&msgFloat, msgSendAddr)
		purego.RegisterFunc(&msgSetFloat, msgSendAddr)
		purego.RegisterLibFunc(&poolPush, libObjC, "objc_autoreleasePoolPush")
		purego.RegisterLibFunc(&poolPop, libObjC, "objc_autoreleasePoolPop")
		purego.RegisterLibFunc(&cfRelease, libCF, "CFRelease")
		purego.RegisterLibFunc(&cfRetain, libCF, "CFRetain")
		purego.RegisterLibFunc(&cfTypeID, libCF, "CFGetTypeID")
		loadAX()
		loadCG()
	})
}

func sel(name string) objc.SEL { return objc.RegisterName(name) }

func class(name string) id {
	c := id(objc.GetClass(name))
	if c == 0 {
		panic("trot: Objective-C class " + name + " not found")
	}
	return c
}

func hasClass(name string) bool { return objc.GetClass(name) != 0 }

// send sends a message whose arguments are integers or pointers.
//
//go:uintptrescapes
func send(obj id, selector string, args ...uintptr) id {
	var a [10]uintptr
	a[0], a[1] = uintptr(obj), uintptr(sel(selector))
	n := copy(a[2:], args)
	r, _, _ := purego.SyscallN(msgSendAddr, a[:n+2]...)
	return id(r)
}

//go:uintptrescapes
func sendBool(obj id, selector string, args ...uintptr) bool {
	return byte(send(obj, selector, args...)) != 0
}

//go:uintptrescapes
func sendInt(obj id, selector string, args ...uintptr) int {
	return int(send(obj, selector, args...))
}

func boolArg(b bool) uintptr {
	if b {
		return 1
	}
	return 0
}

// withPool runs fn in an autorelease pool, on one thread throughout, as a
// pool belongs to the thread that pushed it.
func withPool(fn func()) {
	load()
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	pool := poolPush()
	defer poolPop(pool)
	fn()
}

const utf8Encoding = 4

// nsString returns an autoreleased NSString, which is also a CFStringRef.
func nsString(s string) id {
	b := unsafe.StringData(s)
	str := send(send(class("NSString"), "alloc"), "initWithBytes:length:encoding:",
		uintptr(unsafe.Pointer(b)), uintptr(len(s)), utf8Encoding)
	runtime.KeepAlive(s)
	return send(str, "autorelease")
}

func goString(str id) string {
	if str == 0 {
		return ""
	}
	p := send(str, "UTF8String")
	if p == 0 {
		return ""
	}
	n := sendInt(str, "lengthOfBytesUsingEncoding:", utf8Encoding)
	return string(unsafe.Slice(*(**byte)(unsafe.Pointer(&p)), n))
}

func nsData(b []byte) id {
	var p unsafe.Pointer
	if len(b) > 0 {
		p = unsafe.Pointer(&b[0])
	}
	d := send(class("NSData"), "dataWithBytes:length:", uintptr(p), uintptr(len(b)))
	runtime.KeepAlive(b)
	return d
}

func goBytes(data id) []byte {
	if data == 0 {
		return nil
	}
	n := sendInt(data, "length")
	if n == 0 {
		return []byte{}
	}
	p := send(data, "bytes")
	return append([]byte(nil), unsafe.Slice(*(**byte)(unsafe.Pointer(&p)), n)...)
}

func nsArray(objs ...id) id {
	arr := send(class("NSMutableArray"), "arrayWithCapacity:", uintptr(len(objs)))
	for _, o := range objs {
		send(arr, "addObject:", uintptr(o))
	}
	return arr
}

func arrayItems(arr id) []id {
	if arr == 0 {
		return nil
	}
	n := sendInt(arr, "count")
	out := make([]id, n)
	for i := range n {
		out[i] = send(arr, "objectAtIndex:", uintptr(i))
	}
	return out
}

func isKind(obj id, className string) bool {
	return obj != 0 && hasClass(className) && sendBool(obj, "isKindOfClass:", uintptr(class(className)))
}

func nsError(err id) error {
	if err == 0 {
		return nil
	}
	return fmt.Errorf("%s", goString(send(err, "localizedDescription")))
}
