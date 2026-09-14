// Package cursor turns raw phone deltas into absolute cursor positions.
//
// This is where "feel" lives. The phone sends unaccelerated deltas and knows
// nothing about screen geometry, so the acceleration curve can be retuned here
// without shipping a new client build.
package cursor

import (
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

// resyncAfter is the idle gap after which we re-read the OS cursor position.
// We hold cursor position as state, so a physical mouse moved in the meantime
// would otherwise make the next gesture jump.
const resyncAfter = 500 * time.Millisecond

type Controller struct {
	mu    sync.Mutex
	inj   inject.Injector
	curve Curve

	x, y                   float64
	minX, minY, maxX, maxY float64
	last                   time.Time
}

func New(inj inject.Injector, c Curve) *Controller {
	ctl := &Controller{inj: inj, curve: c}
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

// Move applies one raw delta. dtMS is the interval the phone measured for this
// sample; it drives the speed term of the curve.
func (c *Controller) Move(dx, dy, dtMS float64) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	now := time.Now()
	if now.Sub(c.last) > resyncAfter {
		c.resyncLocked()
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

	ax, ay := dx*gain, dy*gain
	c.x = clamp(c.x+ax, c.minX, c.maxX)
	c.y = clamp(c.y+ay, c.minY, c.maxY)

	return c.inj.MoveTo(c.x, c.y, ax, ay)
}

func (c *Controller) Button(b inject.Button, down bool) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.inj.Button(b, down)
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
