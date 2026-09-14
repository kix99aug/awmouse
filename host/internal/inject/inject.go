// Package inject posts synthetic mouse events to the host OS.
//
// Injection is absolute on every platform: each OS applies its own pointer
// acceleration to relative motion, so relative injection would produce three
// different feels from one delta. Bypassing all of it and positioning the
// cursor directly puts the curve under our control. See DESIGN.md.
package inject

type Button int

const (
	ButtonLeft Button = iota
	ButtonRight
)

type Injector interface {
	// MoveTo positions the cursor in screen coordinates. dx/dy are the
	// post-acceleration deltas that produced this position — some platforms
	// carry them alongside so that apps reading motion rather than position
	// (games, 3D viewports) still see movement.
	MoveTo(x, y, dx, dy float64) error

	Button(b Button, down bool) error

	// Bounds returns the union of all displays, as origin plus size. The origin
	// is not always (0,0): a display placed left of or above the primary one
	// gives the union a negative origin.
	Bounds() (x, y, w, h float64)

	// Position reports the OS cursor location, used to resync when the user has
	// also touched a physical mouse. ok is false where the platform refuses to
	// report it (notably Wayland).
	Position() (x, y float64, ok bool)

	Close() error
}
