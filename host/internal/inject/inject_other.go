//go:build !darwin

package inject

import "errors"

// ErrNotTrusted exists on every platform so callers need no build tags. Only
// darwin currently returns it.
var ErrNotTrusted = errors.New("not trusted for Accessibility")

// New is a placeholder until the Windows (SendInput) and Linux (uinput)
// injectors land. See DESIGN.md for the API each will use.
func New() (Injector, error) {
	return nil, errors.New("no injector for this platform yet")
}
