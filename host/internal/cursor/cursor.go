// Package cursor turns raw phone deltas into absolute cursor positions.
//
// This is where "feel" lives. The phone sends unaccelerated deltas and knows
// nothing about screen geometry, so the acceleration curve can be retuned here
// without shipping a new client build.
package cursor

import (
	"log"
	"math"
	"sync"
	"time"

	"awmouse/host/internal/inject"
)

// Curve maps pointer speed to a gain multiplier:
//
//	gain = clamp(Base + K*speed^P, Min, Max)
//
// where speed is in points/second of finger travel.
type Curve struct {
	Base float64
	K    float64
	P    float64
	Min  float64
	Max  float64
}

// DefaultCurve is a starting point, not a tuned result. It aims for roughly
// 0.8x gain during slow precise movement (~60 pt/s) and ~4x during a fast swipe
// (~2500 pt/s), so the cursor can cross a large display in one gesture without
// losing pixel-level control.
var DefaultCurve = Curve{Base: 0.72, K: 0.0013, P: 1.0, Min: 0.5, Max: 5.0}

// Scroll uses a flat multiplier rather than the pointer curve: scrolling reads
// as distance travelled, not as velocity, so acceleration makes it feel loose.
type ScrollConfig struct {
	Gain   float64
	Invert bool
}

var DefaultScroll = ScrollConfig{Gain: 1.6, Invert: false}

// resyncAfter is the idle gap after which we re-read the OS cursor position.
// We hold cursor position as state, so a physical mouse moved in the meantime
// would otherwise make the next gesture jump.
const resyncAfter = 500 * time.Millisecond

// Motion is not applied as it arrives. Each delta is added to a pending
// amount, and a pump drains that amount over roughly the interval at which
// deltas have been arriving, in steps of pumpTick. A delta that arrives
// after a 100 ms gap therefore becomes ~25 small moves over the next 100 ms
// rather than one jump — which is the difference between a cursor that
// glides and one that stutters when the network bunches messages up.
//
// The cost is up to one inter-arrival interval of latency, and the motion
// starts on the first tick, so the felt lag is a fraction of that. On a fast
// link the interval is at or below the display's refresh period and the pump
// is close to transparent.
const (
	// pumpTick is finer than any display refresh, and no finer: below ~4 ms
	// the extra events are never seen, only posted.
	pumpTick = 4 * time.Millisecond

	// intervalDefault is the assumed arrival rate before any is measured, and
	// what a gap longer than intervalMax resets to — a pause is not a rate.
	intervalDefault = 16 * time.Millisecond
	intervalMin     = pumpTick
	intervalMax     = 250 * time.Millisecond
)

type Controller struct {
	mu     sync.Mutex
	inj    inject.Injector
	curve  Curve
	scroll ScrollConfig

	x, y                   float64
	minX, minY, maxX, maxY float64
	last                   time.Time

	// Scroll deltas are emitted in whole units, so the fractional part has to
	// survive between samples. Truncating each sample independently would make
	// slow scrolling do nothing at all.
	scrollAccX, scrollAccY float64

	held map[inject.Button]bool

	// Motion waiting to be shown, post-acceleration, and the pump that shows
	// it. interval is an estimate of how far apart deltas arrive.
	pendingX, pendingY float64
	interval           time.Duration
	pumping            bool
	stopped            bool
}

func New(inj inject.Injector, c Curve, s ScrollConfig) *Controller {
	ctl := &Controller{
		inj:      inj,
		curve:    c,
		scroll:   s,
		held:     map[inject.Button]bool{},
		interval: intervalDefault,
	}
	ctl.mu.Lock()
	ctl.resyncLocked()
	ctl.mu.Unlock()
	return ctl
}

// resyncLocked refreshes both screen geometry and cursor position from the OS.
// Geometry is refreshed alongside position because displays can be plugged,
// unplugged, or rearranged while we run.
func (c *Controller) resyncLocked() {
	ox, oy, w, h := c.inj.Bounds()
	c.minX, c.minY = ox, oy
	c.maxX, c.maxY = ox+w-1, oy+h-1

	if x, y, ok := c.inj.Position(); ok {
		c.x, c.y = x, y
	}
	c.x = clamp(c.x, c.minX, c.maxX)
	c.y = clamp(c.y, c.minY, c.maxY)
}

// Move accepts one raw delta. dtMS is the interval the phone measured for
// this sample; it drives the speed term of the curve. The accelerated result
// is queued for the pump rather than applied here.
func (c *Controller) Move(dx, dy, dtMS float64) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	now := time.Now()
	// Resyncing mid-drag would tear the drag, and the position cannot have
	// drifted anyway while we hold the button.
	if len(c.held) == 0 && now.Sub(c.last) > resyncAfter {
		c.resyncLocked()
	}
	if !c.last.IsZero() {
		c.observeIntervalLocked(now.Sub(c.last))
	}
	c.last = now

	dt := dtMS / 1000
	// Guard nonsense: a missing dt, or one so large it would flatten the curve
	// to zero gain. Coalesced samples legitimately carry a larger dt, so the cap
	// is generous rather than tight.
	if dt <= 0 || dt > 0.25 {
		dt = 1.0 / 120
	}

	speed := math.Hypot(dx, dy) / dt
	gain := clamp(c.curve.Base+c.curve.K*math.Pow(speed, c.curve.P), c.curve.Min, c.curve.Max)

	c.pendingX += dx * gain
	c.pendingY += dy * gain

	if !c.pumping && !c.stopped {
		c.pumping = true
		go c.pump()
	}
	return nil
}

// observeIntervalLocked folds one inter-arrival gap into the estimate. An
// exponential average tracks a changing rate without reacting to every
// jittered packet; a gap past intervalMax is a pause, not data, and resets.
func (c *Controller) observeIntervalLocked(gap time.Duration) {
	if gap > intervalMax {
		c.interval = intervalDefault
		return
	}
	if gap < intervalMin {
		gap = intervalMin
	}
	c.interval = (c.interval*3 + gap) / 4
}

// pump drains pending motion in pumpTick steps sized so that what is pending
// now is shown over about one inter-arrival interval. It exits when there is
// nothing left, and Move starts a new one when there is.
func (c *Controller) pump() {
	t := time.NewTicker(pumpTick)
	defer t.Stop()

	for range t.C {
		c.mu.Lock()
		if c.stopped {
			c.pumping = false
			c.mu.Unlock()
			return
		}

		// Fraction of what's pending to emit this tick. Never more than all
		// of it, and — once the remainder is below a pixel — all of it, so the
		// tail does not trickle out in sub-pixel dribbles.
		frac := float64(pumpTick) / float64(c.interval)
		if frac > 1 || math.Hypot(c.pendingX, c.pendingY) < 1 {
			frac = 1
		}
		sx, sy := c.pendingX*frac, c.pendingY*frac
		c.pendingX -= sx
		c.pendingY -= sy

		nx := clamp(c.x+sx, c.minX, c.maxX)
		ny := clamp(c.y+sy, c.minY, c.maxY)
		// Motion clamped away at a screen edge is gone, not saved up; a cursor
		// that finally leaves the edge should not lurch by what it couldn't
		// show earlier.
		c.x, c.y = nx, ny
		err := c.inj.MoveTo(c.x, c.y, sx, sy)

		done := c.pendingX == 0 && c.pendingY == 0
		if done {
			c.pumping = false
		}
		c.mu.Unlock()

		if err != nil {
			log.Printf("move: %v", err)
		}
		if done {
			return
		}
	}
}

// flushLocked applies all pending motion at once. The pump, if running, will
// find nothing left and exit on its next tick.
func (c *Controller) flushLocked() error {
	if c.pendingX == 0 && c.pendingY == 0 {
		return nil
	}
	sx, sy := c.pendingX, c.pendingY
	c.pendingX, c.pendingY = 0, 0
	c.x = clamp(c.x+sx, c.minX, c.maxX)
	c.y = clamp(c.y+sy, c.minY, c.maxY)
	return c.inj.MoveTo(c.x, c.y, sx, sy)
}

// Stop ends the pump and discards pending motion. For shutdown and tests.
func (c *Controller) Stop() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.stopped = true
	c.pendingX, c.pendingY = 0, 0
}

// SetScroll replaces the scroll configuration. Safe to call while running;
// the GUI changes it from a slider.
func (c *Controller) SetScroll(s ScrollConfig) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.scroll = s
}

func (c *Controller) Scroll(dx, dy float64) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	sign := 1.0
	if c.scroll.Invert {
		sign = -1
	}

	c.scrollAccX += dx * c.scroll.Gain * sign
	c.scrollAccY += dy * c.scroll.Gain * sign

	ix := math.Trunc(c.scrollAccX)
	iy := math.Trunc(c.scrollAccY)
	c.scrollAccX -= ix
	c.scrollAccY -= iy

	if ix == 0 && iy == 0 {
		return nil
	}
	return c.inj.Scroll(ix, iy)
}

func (c *Controller) Button(b inject.Button, down bool) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	// A click lands where the cursor is, not where it is heading. Show
	// whatever motion is still pending first, or the press falls short of
	// the target by however much the pump had left to play.
	if err := c.flushLocked(); err != nil {
		return err
	}

	if down {
		c.held[b] = true
	} else {
		delete(c.held, b)
	}
	return c.inj.Button(b, down)
}

// ReleaseAll drops any held button. Call it when a client disconnects: a
// connection lost mid-drag would otherwise leave the button stuck down, and the
// user has no mouse to fix it with.
func (c *Controller) ReleaseAll() {
	c.mu.Lock()
	defer c.mu.Unlock()

	for b := range c.held {
		_ = c.inj.Button(b, false)
		delete(c.held, b)
	}
}

func clamp(v, lo, hi float64) float64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
