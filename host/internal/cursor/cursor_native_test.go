//go:build darwin || windows

package cursor

import (
	"testing"
	"time"

	"awmouse/host/internal/inject"
)

// TestMoveMovesRealCursor is the end-to-end check that native injection
// actually reaches the window server — CGEventPost on macOS, SendInput on
// Windows. It moves the real cursor, then puts it back.
func TestMoveMovesRealCursor(t *testing.T) {
	inj, err := inject.New()
	if err != nil {
		t.Skipf("no injector: %v", err)
	}
	defer inj.Close()

	startX, startY, ok := inj.Position()
	if !ok {
		t.Fatal("cannot read cursor position")
	}
	t.Cleanup(func() {
		_ = inj.MoveTo(startX, startY, 0, 0)
	})

	ctl := New(inj, DefaultCurve, DefaultScroll)

	// Move away from wherever we started, so the assertion can't pass by
	// accident from being clamped against a screen edge.
	const dx, dy = 120, 80
	if err := ctl.Move(dx, dy, 16); err != nil {
		t.Fatalf("move: %v", err)
	}

	// CGEventPost is asynchronous and SendInput queues, so the position is
	// not updated on return; poll rather than guess a delay.
	//
	// If this fails on Windows with the cursor exactly where it started,
	// check the foreground window before suspecting the injector: an
	// elevated process, or a game with anti-cheat, makes Windows drop
	// injected input silently.
	var gotX, gotY float64
	deadline := time.Now().Add(2 * time.Second)
	for {
		gotX, gotY, _ = inj.Position()
		if gotX != startX || gotY != startY {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("cursor did not move: still at (%.0f, %.0f)", startX, startY)
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Logf("cursor moved (%.0f,%.0f) -> (%.0f,%.0f) for delta (%d,%d)",
		startX, startY, gotX, gotY, dx, dy)
}

func TestCurveGainRisesWithSpeed(t *testing.T) {
	c := DefaultCurve
	gain := func(speed float64) float64 {
		return clamp(c.Base+c.K*speed, c.Min, c.Max)
	}
	slow, fast := gain(60), gain(2500)
	if !(slow < fast) {
		t.Fatalf("gain should rise with speed: slow=%.2f fast=%.2f", slow, fast)
	}
	if slow < 0.5 || slow > 1.2 {
		t.Errorf("slow gain %.2f outside the intended precision range", slow)
	}
	if fast < 3 || fast > 5 {
		t.Errorf("fast gain %.2f outside the intended traversal range", fast)
	}
	t.Logf("gain: slow(60pt/s)=%.2f  fast(2500pt/s)=%.2f", slow, fast)
}
