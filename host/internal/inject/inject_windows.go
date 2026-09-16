//go:build windows

package inject

import (
	"errors"
	"fmt"
	"math"
	"unsafe"

	"golang.org/x/sys/windows"
)

// NewLazySystemDLL resolves only from System32, so a user32.dll dropped next to
// the binary cannot be picked up in its place.
var (
	user32 = windows.NewLazySystemDLL("user32.dll")

	procSendInput                     = user32.NewProc("SendInput")
	procGetCursorPos                  = user32.NewProc("GetCursorPos")
	procGetSystemMetrics              = user32.NewProc("GetSystemMetrics")
	procSetProcessDpiAwarenessContext = user32.NewProc("SetProcessDpiAwarenessContext")
	procSetProcessDPIAware            = user32.NewProc("SetProcessDPIAware")
)

const (
	inputMouse = 0

	mouseeventfMove        = 0x0001
	mouseeventfLeftDown    = 0x0002
	mouseeventfLeftUp      = 0x0004
	mouseeventfRightDown   = 0x0008
	mouseeventfRightUp     = 0x0010
	mouseeventfMiddleDown  = 0x0020
	mouseeventfMiddleUp    = 0x0040
	mouseeventfWheel       = 0x0800
	mouseeventfHWheel      = 0x1000
	mouseeventfVirtualDesk = 0x4000
	mouseeventfAbsolute    = 0x8000

	smXVirtualScreen  = 76
	smYVirtualScreen  = 77
	smCXVirtualScreen = 78
	smCYVirtualScreen = 79

	// Absolute coordinates are normalised so that 65535 is the far edge.
	absoluteRange = 65535

	// One wheel notch is 120 units and scrolls roughly three lines; treating a
	// scroll unit from the phone as about half a line lands in the same range
	// as the macOS injector. Fine-tune with -scroll-gain rather than here.
	wheelPerUnit = 2
)

// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 is the pseudo-handle -4.
var dpiAwarenessPerMonitorV2 = ^uintptr(3)

// mouseInput mirrors MOUSEINPUT. Field order and types must match the C
// declaration exactly; Go's alignment rules then reproduce the C layout,
// including the padding before dwExtraInfo on 64-bit.
type mouseInput struct {
	dx          int32
	dy          int32
	mouseData   uint32
	dwFlags     uint32
	time        uint32
	dwExtraInfo uintptr
}

// input mirrors INPUT with only the mouse member of its union. The union is
// aligned to its widest member, which Go reproduces because mouseInput carries
// a uintptr.
type input struct {
	typ uint32
	mi  mouseInput
}

type windowsInjector struct {
	// Tracked so that Close can release anything still pressed if the process
	// is told to exit mid-drag.
	held map[Button]bool
}

// New returns an Injector for the current platform.
func New() (Injector, error) {
	if err := procSendInput.Find(); err != nil {
		return nil, fmt.Errorf("SendInput unavailable: %w", err)
	}
	declareDPIAwareness()
	return &windowsInjector{held: map[Button]bool{}}, nil
}

// declareDPIAwareness stops Windows from lying to us about geometry. A process
// that does not declare awareness is handed virtualised, scaled coordinates on
// high-DPI displays — GetSystemMetrics and GetCursorPos disagree with where
// the cursor actually lands, and absolute positioning drifts by the scale
// factor. Per-monitor V2 is preferred; the older system-wide call is the
// fallback on Windows 10 builds before 1703.
func declareDPIAwareness() {
	if procSetProcessDpiAwarenessContext.Find() == nil {
		// Fails harmlessly if awareness was already fixed by a manifest.
		_, _, _ = procSetProcessDpiAwarenessContext.Call(dpiAwarenessPerMonitorV2)
		return
	}
	if procSetProcessDPIAware.Find() == nil {
		_, _, _ = procSetProcessDPIAware.Call()
	}
}

func (w *windowsInjector) MoveTo(x, y, dx, dy float64) error {
	ox, oy, sw, sh := w.Bounds()
	if sw <= 1 || sh <= 1 {
		return errors.New("virtual screen reports no size")
	}

	// (0,0) maps to the top-left pixel and (65535,65535) to the bottom-right
	// one, so the divisor is the last pixel index rather than the width.
	nx := int32(math.Round((x - ox) * absoluteRange / (sw - 1)))
	ny := int32(math.Round((y - oy) * absoluteRange / (sh - 1)))

	// A move while a button is down is a drag; Windows needs no separate event
	// type for it, unlike macOS. VIRTUALDESK spans every monitor — without it
	// the 0..65535 range covers only the primary display and the cursor cannot
	// leave it.
	return send(mouseInput{
		dx:      nx,
		dy:      ny,
		dwFlags: mouseeventfMove | mouseeventfAbsolute | mouseeventfVirtualDesk,
	})
}

func (w *windowsInjector) Button(b Button, down bool) error {
	var flag uint32
	switch b {
	case ButtonRight:
		flag = pick(down, mouseeventfRightDown, mouseeventfRightUp)
	case ButtonMiddle:
		flag = pick(down, mouseeventfMiddleDown, mouseeventfMiddleUp)
	default:
		flag = pick(down, mouseeventfLeftDown, mouseeventfLeftUp)
	}

	// No click count here: Windows derives double clicks from the timing of
	// the presses itself, so the sequence tracking the macOS injector needs
	// has no counterpart.
	if err := send(mouseInput{dwFlags: flag}); err != nil {
		return err
	}

	if down {
		w.held[b] = true
	} else {
		delete(w.held, b)
	}
	return nil
}

func (w *windowsInjector) Scroll(dx, dy float64) error {
	// Positive wheel data is the wheel rolling away from the user, which
	// scrolls up — the same sign convention as the macOS injector, so
	// -scroll-invert means the same thing on both.
	if dy != 0 {
		if err := send(mouseInput{
			mouseData: uint32(int32(dy * wheelPerUnit)),
			dwFlags:   mouseeventfWheel,
		}); err != nil {
			return err
		}
	}
	if dx != 0 {
		if err := send(mouseInput{
			mouseData: uint32(int32(dx * wheelPerUnit)),
			dwFlags:   mouseeventfHWheel,
		}); err != nil {
			return err
		}
	}
	return nil
}

// Bounds returns the virtual screen: the union of every monitor. Its origin is
// negative when a display sits left of or above the primary one.
func (w *windowsInjector) Bounds() (x, y, wd, h float64) {
	return metric(smXVirtualScreen), metric(smYVirtualScreen),
		metric(smCXVirtualScreen), metric(smCYVirtualScreen)
}

func (w *windowsInjector) Position() (x, y float64, ok bool) {
	var p struct{ x, y int32 }
	r, _, _ := procGetCursorPos.Call(uintptr(unsafe.Pointer(&p)))
	if r == 0 {
		return 0, 0, false
	}
	return float64(p.x), float64(p.y), true
}

func (w *windowsInjector) Close() error {
	for b := range w.held {
		_ = w.Button(b, false)
	}
	return nil
}

func send(mi mouseInput) error {
	in := input{typ: inputMouse, mi: mi}
	// SendInput compares cbSize against its own idea of sizeof(INPUT) and
	// injects nothing on a mismatch, so the struct layout above is load-bearing.
	n, _, callErr := procSendInput.Call(1, uintptr(unsafe.Pointer(&in)), unsafe.Sizeof(in))
	if n != 1 {
		// Zero inserted: the input was blocked. Typically a UAC prompt or a
		// locked desktop is in the way.
		return fmt.Errorf("SendInput injected nothing: %w", callErr)
	}
	return nil
}

// metric reads GetSystemMetrics, which returns a signed int that Call hands
// back widened into a uintptr; the narrowing restores negative origins.
func metric(index int) float64 {
	r, _, _ := procGetSystemMetrics.Call(uintptr(index))
	return float64(int32(r))
}

func pick(cond bool, yes, no uint32) uint32 {
	if cond {
		return yes
	}
	return no
}

// PromptForPermission is a no-op: Windows needs no permission to inject.
func PromptForPermission() {}
