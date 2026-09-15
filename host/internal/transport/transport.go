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

// Conn is what a Session may do to its own connection: answer, and end it.
type Conn interface {
	// Reply writes one message back to the phone. Used once, to answer the
	// hello; the protocol is otherwise one-way.
	Reply(proto.Msg) error
	Close() error
}

// Handler admits connections. One Handler serves a transport; each accepted
// connection gets its own Session, which is where per-connection state —
// whether this phone has proven itself yet — belongs.
type Handler interface {
	// Accept is called once per connection, before any message. peer is the
	// phone's tailcat address, which is derived from its node key and bound
	// to it by WireGuard's cryptokey routing — so it identifies the device,
	// not merely the route. Returning nil refuses the connection.
	Accept(peer string, c Conn) Session
}

type Session interface {
	// OnMessage handles one message. A non-nil error ends the connection.
	OnMessage(proto.Msg) error

	// OnDisconnect must be called for every accepted connection that ends,
	// however it ends. A client lost mid-drag leaves a button held down, and
	// the user has no working mouse left to recover with.
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

// dispatch decodes one JSON message and hands it to s. A malformed message is
// logged and skipped rather than ending the connection: dropping the link
// over one bad frame would leave the user with no mouse. The session's own
// verdict is returned as-is.
func dispatch(s Session, data []byte) error {
	var m proto.Msg
	if err := json.Unmarshal(data, &m); err != nil {
		log.Printf("bad message: %v", err)
		return nil
	}
	return s.OnMessage(m)
}
