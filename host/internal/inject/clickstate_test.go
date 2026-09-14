package inject

import (
	"testing"
	"time"
)

var origin = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

// Two taps in quick succession must reach the application as a double click,
// not as two unrelated single clicks — otherwise nothing that needs a double
// click can be done at all.
func TestConsecutivePressesFormADoubleClick(t *testing.T) {
	var s clickSequence

	first := s.next(ButtonLeft, 100, 100, origin)
	second := s.next(ButtonLeft, 100, 100, origin.Add(120*time.Millisecond))

	if first != 1 || second != 2 {
		t.Errorf("got counts %d then %d, want 1 then 2", first, second)
	}
}

func TestThirdPressFormsATripleClick(t *testing.T) {
	var s clickSequence

	s.next(ButtonLeft, 100, 100, origin)
	s.next(ButtonLeft, 100, 100, origin.Add(100*time.Millisecond))
	third := s.next(ButtonLeft, 100, 100, origin.Add(200*time.Millisecond))

	if third != 3 {
		t.Errorf("got %d, want 3", third)
	}
}

func TestSequenceStopsAtTriple(t *testing.T) {
	var s clickSequence

	var last int64
	for i := range 6 {
		last = s.next(ButtonLeft, 100, 100, origin.Add(time.Duration(i)*100*time.Millisecond))
	}

	if last != maxClickCount {
		t.Errorf("got %d, want the sequence capped at %d", last, maxClickCount)
	}
}

func TestSlowPressesAreSeparateClicks(t *testing.T) {
	var s clickSequence

	s.next(ButtonLeft, 100, 100, origin)
	second := s.next(ButtonLeft, 100, 100, origin.Add(doubleClickInterval+time.Millisecond))

	if second != 1 {
		t.Errorf("got %d, want 1 — presses beyond the interval start over", second)
	}
}

// Clicking in two different places is two intentions, however fast the user is.
func TestPressesFarApartAreSeparateClicks(t *testing.T) {
	var s clickSequence

	s.next(ButtonLeft, 100, 100, origin)
	second := s.next(ButtonLeft, 100+doubleClickSlop+1, 100, origin.Add(50*time.Millisecond))

	if second != 1 {
		t.Errorf("got %d, want 1 — a press beyond the slop starts over", second)
	}
}

// A left click followed by a right click is not a double click of either.
func TestDifferentButtonsDoNotAccumulate(t *testing.T) {
	var s clickSequence

	s.next(ButtonLeft, 100, 100, origin)
	right := s.next(ButtonRight, 100, 100, origin.Add(50*time.Millisecond))

	if right != 1 {
		t.Errorf("got %d, want 1", right)
	}
}

// Press and release must carry the same count, or an application sees a double
// click begin and a single click end.
func TestReleaseRepeatsThePressCount(t *testing.T) {
	var s clickSequence

	s.next(ButtonLeft, 100, 100, origin)
	s.next(ButtonLeft, 100, 100, origin.Add(100*time.Millisecond))

	if got := s.current(); got != 2 {
		t.Errorf("got %d, want the press count 2 repeated", got)
	}
}

// The very first release can precede any recorded press if the client
// reconnects mid-gesture; it must still be a valid click count.
func TestCurrentIsValidBeforeAnyPress(t *testing.T) {
	var s clickSequence

	if got := s.current(); got != 1 {
		t.Errorf("got %d, want 1", got)
	}
}
