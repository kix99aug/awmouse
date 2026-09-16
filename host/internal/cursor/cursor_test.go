package cursor

import (
	"math"
	"sync"
	"testing"
	"time"

	"awmouse/host/internal/inject"
)

type fakeInjector struct {
	mu      sync.Mutex
	moves   [][2]float64 // dx, dy per MoveTo
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

func (f *fakeInjector) MoveTo(x, y, dx, dy float64) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.moves = append(f.moves, [2]float64{dx, dy})
	return nil
}

func (f *fakeInjector) movesSnapshot() [][2]float64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([][2]float64(nil), f.moves...)
}
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

// A delta that arrives after a long gap must be shown as many small moves
// over a comparable span, not as one jump — that is the whole point of the
// pump. And every pixel of it must arrive.
func TestSlowArrivalsAreSpreadIntoManySteps(t *testing.T) {
	f := newFake()
	ctl := New(f, Curve{Base: 1, K: 0, P: 1, Min: 1, Max: 1}, DefaultScroll) // unity gain
	defer ctl.Stop()

	// Two arrivals 100 ms apart teach the controller the rate; the second
	// carries the motion under test.
	_ = ctl.Move(0, 0, 16)
	time.Sleep(100 * time.Millisecond)
	_ = ctl.Move(100, 50, 16)
	waitIdle(t, ctl)

	moves := f.movesSnapshot()
	var sx, sy float64
	steps := 0
	for _, m := range moves {
		sx += m[0]
		sy += m[1]
		if m[0] != 0 || m[1] != 0 {
			steps++
		}
	}
	if steps < 5 {
		t.Fatalf("100px after a 100ms gap was shown in %d step(s); expected many", steps)
	}
	// And the last step must not have been a sub-pixel dribble: the tail is
	// what a geometric drain gets wrong.
	if last := moves[len(moves)-1]; math.Hypot(last[0], last[1]) < 0.5 {
		t.Errorf("drain ended in a %.3f px dribble", math.Hypot(last[0], last[1]))
	}
	if abs(sx-100) > 1e-6 || abs(sy-50) > 1e-6 {
		t.Fatalf("motion lost in the pump: total (%.3f, %.3f), want (100, 50)", sx, sy)
	}
}

// A click must land where the motion was going, not where the pump had got
// to: pending motion is flushed before the button goes down.
func TestButtonFlushesPendingMotion(t *testing.T) {
	f := newFake()
	ctl := New(f, Curve{Base: 1, K: 0, P: 1, Min: 1, Max: 1}, DefaultScroll)
	defer ctl.Stop()

	_ = ctl.Move(0, 0, 16)
	time.Sleep(100 * time.Millisecond)
	_ = ctl.Move(80, 0, 16) // will take ~100 ms to play out
	_ = ctl.Button(inject.ButtonLeft, true)

	// Immediately after the press, all 80px must already have been shown.
	var sx float64
	for _, m := range f.movesSnapshot() {
		sx += m[0]
	}
	if abs(sx-80) > 1e-6 {
		t.Fatalf("press went down with %.1f of 80 px shown", sx)
	}
}

// Fast arrivals must not be held back: at the display's own rate the pump
// should drain each delta within a tick or two.
func TestFastArrivalsAreNotDelayed(t *testing.T) {
	f := newFake()
	ctl := New(f, Curve{Base: 1, K: 0, P: 1, Min: 1, Max: 1}, DefaultScroll)
	defer ctl.Stop()

	for range 5 {
		_ = ctl.Move(4, 0, 8)
		time.Sleep(8 * time.Millisecond)
	}
	waitIdle(t, ctl)

	var sx float64
	for _, m := range f.movesSnapshot() {
		sx += m[0]
	}
	if abs(sx-20) > 1e-6 {
		t.Fatalf("fast stream: %.1f of 20 px shown after settling", sx)
	}
}

// waitIdle blocks until the pump has drained, or fails the test. Waiting
// on the pump's own state rather than sleeping a guessed duration is what
// keeps these tests honest on a loaded CI machine, where ticks arrive late.
func waitIdle(t *testing.T, ctl *Controller) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		ctl.mu.Lock()
		idle := !ctl.pumping
		ctl.mu.Unlock()
		if idle {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("pump never went idle")
		}
		time.Sleep(pumpTick)
	}
}

func abs(v float64) float64 {
	if v < 0 {
		return -v
	}
	return v
}
