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
)

const (
	ButtonLeft  = "l"
	ButtonRight = "r"
)

// Msg is every message type in one struct. The protocol is small enough that
// polymorphic decoding would cost more than it saves.
type Msg struct {
	T string `json:"t"`

	// Move: raw unaccelerated delta in points, with the sampling interval that
	// produced it. DT is carried explicitly rather than derived from arrival
	// time so network jitter doesn't smear the acceleration curve.
	DX float64 `json:"dx,omitempty"`
	DY float64 `json:"dy,omitempty"`
	DT float64 `json:"dt,omitempty"` // milliseconds

	// Click.
	B string `json:"b,omitempty"`
	D bool   `json:"d,omitempty"`
}
