//go:build !darwin && !windows

package inject

import "errors"

// New is a placeholder until the Linux (uinput) injector lands. See DESIGN.md
// for the API it will use.
func New() (Injector, error) {
	return nil, errors.New("no injector for this platform yet")
}
