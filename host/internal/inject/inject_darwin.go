//go:build darwin

package inject

/*
#cgo LDFLAGS: -framework ApplicationServices -framework CoreGraphics
#include <ApplicationServices/ApplicationServices.h>

// held: 0 none, 1 left, 2 right, 3 middle
static void moveTo(double x, double y, double dx, double dy, int held) {
	CGEventType t = kCGEventMouseMoved;
	CGMouseButton b = kCGMouseButtonLeft;
	switch (held) {
	case 1: t = kCGEventLeftMouseDragged;  b = kCGMouseButtonLeft;   break;
	case 2: t = kCGEventRightMouseDragged; b = kCGMouseButtonRight;  break;
	case 3: t = kCGEventOtherMouseDragged; b = kCGMouseButtonCenter; break;
	}

	CGEventRef e = CGEventCreateMouseEvent(NULL, t, CGPointMake(x, y), b);
	if (e == NULL) return;
	// Apps that read motion rather than position (games, 3D viewports) see
	// nothing without these, because absolute positioning carries no delta.
	CGEventSetIntegerValueField(e, kCGMouseEventDeltaX, (int64_t)dx);
	CGEventSetIntegerValueField(e, kCGMouseEventDeltaY, (int64_t)dy);
	CGEventPost(kCGHIDEventTap, e);
	CFRelease(e);
}

// which: 0 left, 1 right, 2 middle
static void button(double x, double y, int which, int down, long long clickState) {
	CGEventType t;
	CGMouseButton b;
	switch (which) {
	case 1:
		b = kCGMouseButtonRight;
		t = down ? kCGEventRightMouseDown : kCGEventRightMouseUp;
		break;
	case 2:
		b = kCGMouseButtonCenter;
		t = down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp;
		break;
	default:
		b = kCGMouseButtonLeft;
		t = down ? kCGEventLeftMouseDown : kCGEventLeftMouseUp;
		break;
	}

	CGEventRef e = CGEventCreateMouseEvent(NULL, t, CGPointMake(x, y), b);
	if (e == NULL) return;
	// Without a rising click state, two quick presses are two single clicks:
	// macOS reads the count from the event rather than timing it itself, so
	// double click would never reach any application.
	CGEventSetIntegerValueField(e, kCGMouseEventClickState, clickState);
	CGEventPost(kCGHIDEventTap, e);
	CFRelease(e);
}

static void scrollBy(double dx, double dy) {
	// Pixel units scroll smoothly, the way a trackpad does; line units move in
	// notched steps like an old wheel mouse.
	CGEventRef e = CGEventCreateScrollWheelEvent(
		NULL, kCGScrollEventUnitPixel, 2, (int32_t)dy, (int32_t)dx);
	if (e == NULL) return;
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

import "time"

type darwinInjector struct {
	// held tracks which buttons are down, so that motion during a drag is
	// emitted as a drag event rather than a plain move. Apps that implement
	// text selection or window dragging listen only for the former.
	held map[Button]bool

	clicks clickSequence
}

// New returns an Injector for the current platform.
func New() (Injector, error) {
	if C.trusted() == 0 {
		return nil, ErrNotTrusted
	}
	return &darwinInjector{held: map[Button]bool{}}, nil
}

func (d *darwinInjector) MoveTo(x, y, dx, dy float64) error {
	C.moveTo(C.double(x), C.double(y), C.double(dx), C.double(dy), C.int(d.heldCode()))
	return nil
}

// heldCode picks one held button to attribute drag events to. Simultaneous
// buttons are not a gesture the client can produce, so first match wins.
func (d *darwinInjector) heldCode() int {
	switch {
	case d.held[ButtonLeft]:
		return 1
	case d.held[ButtonRight]:
		return 2
	case d.held[ButtonMiddle]:
		return 3
	default:
		return 0
	}
}

func (d *darwinInjector) Button(b Button, down bool) error {
	x, y, _ := d.Position()

	which := 0
	switch b {
	case ButtonRight:
		which = 1
	case ButtonMiddle:
		which = 2
	}

	dn := 0
	if down {
		dn = 1
	}

	// The press decides the count; the release repeats it, so that both halves
	// of one click agree.
	clickState := d.clicks.current()
	if down {
		clickState = d.clicks.next(b, x, y, time.Now())
	}

	C.button(C.double(x), C.double(y), C.int(which), C.int(dn), C.longlong(clickState))

	if down {
		d.held[b] = true
	} else {
		delete(d.held, b)
	}
	return nil
}

func (d *darwinInjector) Scroll(dx, dy float64) error {
	C.scrollBy(C.double(dx), C.double(dy))
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

func (d *darwinInjector) Close() error {
	// Never leave a button stuck down if the client vanished mid-drag.
	for b := range d.held {
		_ = d.Button(b, false)
	}
	return nil
}
