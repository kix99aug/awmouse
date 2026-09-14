package inject

import "time"

// doubleClickInterval is the window within which consecutive presses form a
// multi-click. macOS exposes this as a user preference; 500 ms is its default
// and is close enough that reading the real value is not worth the cgo.
const doubleClickInterval = 500 * time.Millisecond

// doubleClickSlop is how far the cursor may move between presses and still have
// them count as one sequence.
const doubleClickSlop = 5.0

// maxClickCount caps the sequence at a triple click, which is the deepest
// meaning any common application assigns.
const maxClickCount = 3

// clickSequence counts consecutive presses so that a double tap arrives as a
// real double click rather than as two unrelated single clicks.
//
// The phone cannot supply this. It knows it sent two taps, but not whether the
// host considers them close enough in time and space, and that judgement is the
// platform's to make.
type clickSequence struct {
	button Button
	at     time.Time
	x, y   float64
	count  int64
}

// next reports the click count for a press at the given place and moment.
func (s *clickSequence) next(b Button, x, y float64, now time.Time) int64 {
	continues := s.count > 0 &&
		s.button == b &&
		now.Sub(s.at) <= doubleClickInterval &&
		abs(x-s.x) <= doubleClickSlop &&
		abs(y-s.y) <= doubleClickSlop

	if continues && s.count < maxClickCount {
		s.count++
	} else {
		s.count = 1
	}

	s.button = b
	s.at = now
	s.x, s.y = x, y
	return s.count
}

// current reports the count of the press already in progress, so that the
// release carries the same value as its press.
func (s *clickSequence) current() int64 {
	if s.count < 1 {
		return 1
	}
	return s.count
}

func abs(v float64) float64 {
	if v < 0 {
		return -v
	}
	return v
}
