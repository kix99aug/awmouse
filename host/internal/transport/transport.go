// Package transport carries protocol messages from the phone to the host.
//
// The POC uses a plain LAN WebSocket. tailcat replaces it by implementing this
// same interface, with nothing above this layer changing — deliberately, so the
// input pipeline and the tailcat/gomobile integration can be debugged as two
// separate problems rather than one tangled one. See DESIGN.md.
package transport

import (
	"context"

	"awmouse/host/internal/proto"
)

type Transport interface {
	// Run blocks serving messages until ctx is cancelled.
	Run(ctx context.Context, onMsg func(proto.Msg)) error

	// Endpoint is whatever the phone needs in order to connect: a ws:// URL for
	// the POC, a pairing token once tailcat lands. It gets rendered as the QR
	// code on the host's terminal.
	Endpoint() string
}
