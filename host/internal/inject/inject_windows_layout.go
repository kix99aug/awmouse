//go:build windows && (amd64 || arm64)

package inject

import "unsafe"

// SendInput checks cbSize against sizeof(INPUT) and silently injects nothing
// on a mismatch, so a layout slip in the Go structs would fail without ever
// producing an error. These lines refuse to compile unless the sizes match the
// C definitions on 64-bit Windows: MOUSEINPUT is 32 bytes, and INPUT is a
// 4-byte type, 4 bytes of padding to 8-align the union, then the 32.
var (
	_ = [1]struct{}{}[unsafe.Sizeof(mouseInput{})-32]
	_ = [1]struct{}{}[unsafe.Sizeof(input{})-40]
)
