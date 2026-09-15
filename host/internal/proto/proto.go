// Package proto defines the wire format between the phone and the host daemon.
//
// Deltas on the wire are relative and unaccelerated — the phone is a
// trackpad-style surface. The acceleration curve and absolute positioning both
// live on the host; see DESIGN.md.
package proto

const (
	KindMove   = "m"
	KindClick  = "c"
	KindScroll = "s"

	// KindHello is the phone's first message on every connection. It carries
	// the pairing code from the QR (or typed in), which the host checks only
	// for a phone it has not seen before. The host answers with exactly one
	// KindOK or KindNo; after KindNo it closes the connection. Nothing else
	// ever flows host→phone.
	KindHello = "h"
	KindOK    = "ok"
	KindNo    = "no"
)

// Reasons carried by KindNo.
const (
	// ReasonCode: the phone is not paired and its code was missing or wrong.
	// The phone should ask the user for the code shown on the host.
	ReasonCode = "code"
	// ReasonLocked: too many wrong codes recently; try again shortly.
	ReasonLocked = "locked"
	// ReasonHello: the first message was not a hello.
	ReasonHello = "hello"
)

const (
	ButtonLeft   = "l"
	ButtonRight  = "r"
	ButtonMiddle = "m"
)

// Msg is every message type in one struct. The protocol is small enough that
// polymorphic decoding would cost more than it saves.
type Msg struct {
	T string `json:"t"`

	// Move and scroll: raw unaccelerated delta in points, with the sampling
	// interval that produced it. DT is carried explicitly rather than derived
	// from arrival time so network jitter doesn't smear the acceleration curve.
	DX float64 `json:"dx,omitempty"`
	DY float64 `json:"dy,omitempty"`
	DT float64 `json:"dt,omitempty"` // milliseconds

	// Click.
	B string `json:"b,omitempty"`
	D bool   `json:"d,omitempty"`

	// Hello: the pairing code and a display name for the host's device list.
	Code string `json:"code,omitempty"`
	Name string `json:"name,omitempty"`

	// No: why.
	Reason string `json:"reason,omitempty"`
}
