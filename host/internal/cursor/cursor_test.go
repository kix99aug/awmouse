package cursor

import (
	"testing"

	"awmouse/host/internal/inject"
)

type fakeInjector struct {
	scrolls [][2]float64
	buttons []struct {
		b    inject.Button
		down bool
	}
	held map[inject.Button]bool
}

func newFake() *fakeInjector {
	return &fakeInjector{held: map[inject.Button]bool{}}
}

func (f *fakeInjector) MoveTo(x, y, dx, dy float64) error { return nil }
func (f *fakeInjector) Scroll(dx, dy float64) error {
	f.scrolls = append(f.scrolls, [2]float64{dx, dy})
	return nil
}
func (f *fakeInjector) Button(b inject.Button, down bool) error {
	f.buttons = append(f.buttons, struct {
		b    inject.Button
		down bool
	}{b, down})
	if down {
		f.held[b] = true
	} else {
		delete(f.held, b)
	}
	return nil
}
func (f *fakeInjector) Bounds() (x, y, w, h float64)      { return 0, 0, 1920, 1080 }
func (f *fakeInjector) Position() (x, y float64, ok bool) { return 100, 100, true }
func (f *fakeInjector) Close() error                      { return nil }

// Scroll is emitted in whole units. Truncating each sample independently would
// make slow two-finger scrolling do nothing whatsoever, since every sample
// would floor to zero.
func TestSlowScrollAccumulatesInsteadOfVanishing(t *testing.T) {
	f := newFake()
	ctl := New(f, DefaultCurve, ScrollConfig{Gain: 1})

	// 0.25 is exact in binary, so the arithmetic here carries no representation
	// error and the expected total is unambiguous.
	for range 8 {
		if err := ctl.Scroll(0, 0.25); err != nil {
			t.Fatalf("scroll: %v", err)
		}
	}

	if total := totalScrollY(f); total != 2 {
		t.Errorf("accumulated scroll = %v, want 2 (emitted %d events)", total, len(f.scrolls))
	}
}

// The general invariant, stated in a way that survives float representation:
// whatever was fed in comes out, minus at most the sub-unit remainder still
// waiting in the accumulator.
func TestScrollLosesNothingBeyondPendingRemainder(t *testing.T) {
	f := newFake()
	ctl := New(f, DefaultCurve, ScrollConfig{Gain: 1})

	// Summed in the loop rather than as sample*count: Go evaluates untyped
	// constant arithmetic at arbitrary precision, so the constant product would
	// be exactly 3 while repeated float64 addition lands just under it — and
	// the invariant is about what was actually fed in.
	const sample, count = 0.3, 10
	var in float64
	for range count {
		if err := ctl.Scroll(0, sample); err != nil {
			t.Fatalf("scroll: %v", err)
		}
		in += sample
	}

	out := totalScrollY(f)
	if out > in || in-out >= 1 {
		t.Errorf("emitted %v for input %v; shortfall must be a sub-unit remainder", out, in)
	}
}

func totalScrollY(f *fakeInjector) float64 {
	var total float64
	for _, s := range f.scrolls {
		total += s[1]
	}
	return total
}

func TestScrollInvertFlipsDirection(t *testing.T) {
	f := newFake()
	ctl := New(f, DefaultCurve, ScrollConfig{Gain: 1, Invert: true})

	if err := ctl.Scroll(0, 5); err != nil {
		t.Fatalf("scroll: %v", err)
	}
	if len(f.scrolls) != 1 || f.scrolls[0][1] != -5 {
		t.Errorf("got %v, want one event of -5", f.scrolls)
	}
}

// A client lost mid-drag would otherwise leave the button stuck down, and the
// user has no working mouse left to recover with.
func TestReleaseAllFreesHeldButtons(t *testing.T) {
	f := newFake()
	ctl := New(f, DefaultCurve, DefaultScroll)

	if err := ctl.Button(inject.ButtonLeft, true); err != nil {
		t.Fatalf("button: %v", err)
	}
	if !f.held[inject.ButtonLeft] {
		t.Fatal("button should be held")
	}

	ctl.ReleaseAll()

	if len(f.held) != 0 {
		t.Errorf("buttons still held after ReleaseAll: %v", f.held)
	}
}

func TestReleaseAllIsNoOpWhenNothingHeld(t *testing.T) {
	f := newFake()
	ctl := New(f, DefaultCurve, DefaultScroll)

	ctl.ReleaseAll()

	if len(f.buttons) != 0 {
		t.Errorf("unexpected button events: %v", f.buttons)
	}
}
