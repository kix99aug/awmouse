//go:build darwin

package inject

/*
#cgo LDFLAGS: -framework ApplicationServices -framework CoreGraphics
#include <ApplicationServices/ApplicationServices.h>

static void moveTo(double x, double y, double dx, double dy) {
	CGEventRef e = CGEventCreateMouseEvent(
		NULL, kCGEventMouseMoved, CGPointMake(x, y), kCGMouseButtonLeft);
	if (e == NULL) return;
	// Apps that read motion rather than position (games, 3D viewports) see
	// nothing without these, because absolute positioning carries no delta.
	CGEventSetIntegerValueField(e, kCGMouseEventDeltaX, (int64_t)dx);
	CGEventSetIntegerValueField(e, kCGMouseEventDeltaY, (int64_t)dy);
	CGEventPost(kCGHIDEventTap, e);
	CFRelease(e);
}

static void button(double x, double y, int right, int down) {
	CGEventType t;
	CGMouseButton b;
	if (right) {
		b = kCGMouseButtonRight;
		t = down ? kCGEventRightMouseDown : kCGEventRightMouseUp;
	} else {
		b = kCGMouseButtonLeft;
		t = down ? kCGEventLeftMouseDown : kCGEventLeftMouseUp;
	}
	CGEventRef e = CGEventCreateMouseEvent(NULL, t, CGPointMake(x, y), b);
	if (e == NULL) return;
	CGEventSetIntegerValueField(e, kCGMouseEventClickState, 1);
	CGEventPost(kCGHIDEventTap, e);
	CFRelease(e);
}

static void screenBounds(double *x, double *y, double *w, double *h) {
	CGDirectDisplayID ids[16];
	uint32_t n = 0;
	CGRect u;
	if (CGGetActiveDisplayList(16, ids, &n) != kCGErrorSuccess || n == 0) {
		u = CGDisplayBounds(CGMainDisplayID());
	} else {
		u = CGDisplayBounds(ids[0]);
		for (uint32_t i = 1; i < n; i++) {
			u = CGRectUnion(u, CGDisplayBounds(ids[i]));
		}
	}
	*x = u.origin.x; *y = u.origin.y;
	*w = u.size.width; *h = u.size.height;
}

static void cursorPos(double *x, double *y) {
	CGEventRef e = CGEventCreate(NULL);
	if (e == NULL) { *x = 0; *y = 0; return; }
	CGPoint p = CGEventGetLocation(e);
	CFRelease(e);
	*x = p.x; *y = p.y;
}

static int trusted(void) { return AXIsProcessTrusted() ? 1 : 0; }
*/
import "C"

import "errors"

// ErrNotTrusted means the process lacks Accessibility permission, without which
// CGEventPost silently does nothing.
//
// The grant attaches to the binary that owns the process — so when running from
// a terminal it is the *terminal app* (Terminal, iTerm) that must be listed in
// System Settings › Privacy & Security › Accessibility, not this binary. This
// catches everyone at least once.
var ErrNotTrusted = errors.New(
	"not trusted for Accessibility: grant the app running this binary " +
		"(your terminal, if launched from a shell) access in " +
		"System Settings > Privacy & Security > Accessibility")

type darwinInjector struct{}

// New returns an Injector for the current platform.
func New() (Injector, error) {
	if C.trusted() == 0 {
		return nil, ErrNotTrusted
	}
	return &darwinInjector{}, nil
}

func (d *darwinInjector) MoveTo(x, y, dx, dy float64) error {
	C.moveTo(C.double(x), C.double(y), C.double(dx), C.double(dy))
	return nil
}

func (d *darwinInjector) Button(b Button, down bool) error {
	x, y, _ := d.Position()
	right := 0
	if b == ButtonRight {
		right = 1
	}
	dn := 0
	if down {
		dn = 1
	}
	C.button(C.double(x), C.double(y), C.int(right), C.int(dn))
	return nil
}

func (d *darwinInjector) Bounds() (x, y, w, h float64) {
	var cx, cy, cw, ch C.double
	C.screenBounds(&cx, &cy, &cw, &ch)
	return float64(cx), float64(cy), float64(cw), float64(ch)
}

func (d *darwinInjector) Position() (x, y float64, ok bool) {
	var cx, cy C.double
	C.cursorPos(&cx, &cy)
	return float64(cx), float64(cy), true
}

func (d *darwinInjector) Close() error { return nil }
