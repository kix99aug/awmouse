package proto

import (
	"encoding/json"
	"testing"
)

// The payloads below are what Swift's JSONEncoder emits for the Msg struct in
// ios/AWMouse/Protocol.swift. A field renamed on one side and not the other
// fails silently at runtime — the host would decode a zero value and simply
// stop moving — so pin the exact shapes here.
func TestDecodesSwiftPayloads(t *testing.T) {
	tests := []struct {
		name string
		json string
		want Msg
	}{
		{
			name: "move",
			json: `{"t":"m","dx":12.5,"dy":-4,"dt":33}`,
			want: Msg{T: KindMove, DX: 12.5, DY: -4, DT: 33},
		},
		{
			name: "left down",
			json: `{"t":"c","b":"l","d":true}`,
			want: Msg{T: KindClick, B: ButtonLeft, D: true},
		},
		{
			// Swift's Encodable drops only nil optionals, so an explicit
			// `false` is transmitted rather than omitted. Button-up therefore
			// arrives as a present key, not an absent one.
			name: "left up",
			json: `{"t":"c","b":"l","d":false}`,
			want: Msg{T: KindClick, B: ButtonLeft, D: false},
		},
		{
			name: "right down",
			json: `{"t":"c","b":"r","d":true}`,
			want: Msg{T: KindClick, B: ButtonRight, D: true},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var got Msg
			if err := json.Unmarshal([]byte(tc.json), &got); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if got != tc.want {
				t.Errorf("got %+v, want %+v", got, tc.want)
			}
		})
	}
}

// A move with a missing dt must stay distinguishable from dt=0, because the
// cursor controller substitutes a default only when dt is absent or absurd.
func TestMoveWithoutDT(t *testing.T) {
	var got Msg
	if err := json.Unmarshal([]byte(`{"t":"m","dx":3,"dy":3}`), &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got.DT != 0 {
		t.Errorf("absent dt should decode to 0, got %v", got.DT)
	}
}
