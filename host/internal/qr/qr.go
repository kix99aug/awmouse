// Package qr renders pairing codes as PNG, using the encoder the terminal
// version already depended on so no new dependency is taken on.
package qr

import "rsc.io/qr"

// PNG encodes text at the given pixels-per-module scale, with the standard
// quiet zone. Error correction is the lowest level: the payload is a long
// tunnel address, and a phone camera reads a sparser code more easily than a
// denser, more redundant one.
func PNG(text string, scale int) ([]byte, error) {
	code, err := qr.Encode(text, qr.L)
	if err != nil {
		return nil, err
	}
	code.Scale = scale
	return code.PNG(), nil
}
