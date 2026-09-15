// Package transport carries protocol messages from the phone to the host.
//
// The only transport is tailcat. The interface remains because it is what let
// the input pipeline be built and debugged over a plain WebSocket before the
// tunnel existed, and because the tests still drive the tunnel through it over
// a loopback relay. See DESIGN.md.
package transport

import (
	"context"
	"encoding/json"
	"log"

	"awmouse/host/internal/proto"
)

type Handler interface {
	// OnConnect is called once per accepted connection, before any message.
	// peer is whatever the transport can say about the other end — an address
	// for the LAN, a key fingerprint for the tunnel — and is for display only.
	OnConnect(peer string)

	OnMessage(proto.Msg)

	// OnDisconnect must be called for every connection that ends, however it
	// ends. A client lost mid-drag leaves a button held down, and the user has
	// no working mouse left to recover with.
	OnDisconnect()
}

type Transport interface {
	// Run blocks serving messages until ctx is cancelled.
	Run(ctx context.Context, h Handler) error

	// Endpoint is the deep link the phone opens to connect — the pairing
	// address wrapped as awmouse://pair?tc=… — and is what the host renders as
	// its QR code.
	Endpoint() string
}

// dispatch decodes one JSON message and hands it to h. A malformed message is
// logged and skipped rather than ending the connection: dropping the link
// over one bad frame would leave the user with no mouse.
func dispatch(h Handler, data []byte) {
	var m proto.Msg
	if err := json.Unmarshal(data, &m); err != nil {
		log.Printf("bad message: %v", err)
		return
	}
	h.OnMessage(m)
}
