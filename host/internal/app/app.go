// Package app wires the injector, cursor controller, and transport together
// and exposes their combined state, so that a user interface only has to
// render it.
//
// Everything that used to live in the daemon's main() is here, plus what a
// window needs and a terminal never did: a transport that can be swapped while
// running, settings that change without a restart, and a permission gate that
// waits instead of exiting.
package app

import (
	"context"
	"errors"
	"fmt"
	"log"
	"sync"
	"time"

	"awmouse/host/internal/cursor"
	"awmouse/host/internal/inject"
	"awmouse/host/internal/proto"
	"awmouse/host/internal/transport"
)

type TransportKind string

const (
	// TransportLAN is a WebSocket reachable on the local network.
	TransportLAN TransportKind = "lan"
	// TransportTunnel is tailcat: reachable from anywhere, end-to-end
	// encrypted, brokered through a relay until a direct path exists.
	TransportTunnel TransportKind = "tunnel"
)

type Settings struct {
	Transport    TransportKind
	Port         int
	IdentityPath string // tailcat identity file; empty means the per-user default
	ScrollGain   float64
	ScrollInvert bool
}

func DefaultSettings() Settings {
	return Settings{
		Transport:  TransportLAN,
		Port:       8787,
		ScrollGain: cursor.DefaultScroll.Gain,
	}
}

type Phase int

const (
	// PhaseNeedsPermission: the OS will not let us post input yet. macOS only
	// in practice — Accessibility must be granted in System Settings, and the
	// app keeps checking until it is.
	PhaseNeedsPermission Phase = iota
	// PhaseStarting: the transport is coming up. The tunnel takes a second or
	// two to measure relays; the LAN listener is effectively instant.
	PhaseStarting
	// PhaseListening: ready, nothing connected.
	PhaseListening
	// PhaseConnected: a phone is driving the cursor.
	PhaseConnected
	// PhaseFailed: the transport could not start. Error says why. The app
	// stays up so the user can switch transports or fix the cause.
	PhaseFailed
)

func (p Phase) String() string {
	switch p {
	case PhaseNeedsPermission:
		return "needs permission"
	case PhaseStarting:
		return "starting"
	case PhaseListening:
		return "listening"
	case PhaseConnected:
		return "connected"
	case PhaseFailed:
		return "failed"
	}
	return "unknown"
}

// Status is a snapshot for display. Every field is safe to show; nothing here
// is a secret except Endpoint and Address, which are what the phone needs and
// which the user is meant to see.
type Status struct {
	Phase     Phase
	Transport TransportKind
	// Endpoint is the QR payload — the deep link the phone opens.
	Endpoint string
	// Address is the human-readable form for typing in by hand.
	Address string
	Peer    string
	Error   string
}

type App struct {
	mu       sync.Mutex
	settings Settings
	status   Status
	subs     map[chan Status]struct{}

	inj inject.Injector
	ctl *cursor.Controller

	// The running transport, if any. Swapping transports cancels the old
	// context and waits on done before starting the next, so two listeners
	// never fight over a port or an identity file.
	cancelTransport context.CancelFunc
	transportDone   chan struct{}
}

func New(s Settings) *App {
	return &App{
		settings: s,
		status:   Status{Phase: PhaseStarting, Transport: s.Transport},
		subs:     map[chan Status]struct{}{},
	}
}

// Run blocks until ctx is cancelled. It first waits for the OS to allow input
// injection, then keeps a transport running according to the settings.
func (a *App) Run(ctx context.Context) error {
	inj, err := a.acquireInjector(ctx)
	if err != nil {
		return err
	}
	defer inj.Close()

	a.mu.Lock()
	a.inj = inj
	a.ctl = cursor.New(inj, cursor.DefaultCurve, cursor.ScrollConfig{
		Gain:   a.settings.ScrollGain,
		Invert: a.settings.ScrollInvert,
	})
	kind := a.settings.Transport
	a.mu.Unlock()

	a.startTransport(ctx, kind)

	<-ctx.Done()
	a.stopTransport()
	return nil
}

// acquireInjector polls until the platform lets us inject. On macOS that is
// the Accessibility grant, which the user makes in System Settings while we
// wait; there is nothing to do but check again.
func (a *App) acquireInjector(ctx context.Context) (inject.Injector, error) {
	for {
		inj, err := inject.New()
		if err == nil {
			return inj, nil
		}
		if !errors.Is(err, inject.ErrNotTrusted) {
			a.update(func(s *Status) {
				s.Phase = PhaseFailed
				s.Error = err.Error()
			})
			return nil, err
		}

		a.update(func(s *Status) {
			s.Phase = PhaseNeedsPermission
			s.Error = ""
		})

		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(1500 * time.Millisecond):
		}
	}
}

// startTransport brings up a transport of the given kind in the background.
// Must not be called while one is running; use SetTransport for that.
func (a *App) startTransport(parent context.Context, kind TransportKind) {
	ctx, cancel := context.WithCancel(parent)
	done := make(chan struct{})

	a.mu.Lock()
	a.cancelTransport = cancel
	a.transportDone = done
	port := a.settings.Port
	identity := a.settings.IdentityPath
	a.mu.Unlock()

	a.update(func(s *Status) {
		s.Phase = PhaseStarting
		s.Transport = kind
		s.Endpoint, s.Address, s.Peer, s.Error = "", "", "", ""
	})

	go func() {
		defer close(done)

		tr, address, err := open(ctx, kind, port, identity)
		if err != nil {
			if ctx.Err() != nil {
				return // cancelled mid-start; not a failure worth showing
			}
			log.Printf("transport %s: %v", kind, err)
			a.update(func(s *Status) {
				s.Phase = PhaseFailed
				s.Error = err.Error()
			})
			return
		}

		a.update(func(s *Status) {
			s.Phase = PhaseListening
			s.Endpoint = tr.Endpoint()
			s.Address = address
		})

		if err := tr.Run(ctx, &handler{app: a}); err != nil && ctx.Err() == nil {
			log.Printf("transport %s: %v", kind, err)
			a.update(func(s *Status) {
				s.Phase = PhaseFailed
				s.Error = err.Error()
			})
		}
	}()
}

func (a *App) stopTransport() {
	a.mu.Lock()
	cancel, done := a.cancelTransport, a.transportDone
	a.cancelTransport, a.transportDone = nil, nil
	a.mu.Unlock()

	if cancel != nil {
		cancel()
		<-done
	}
	// A phone that was mid-drag when the listener went away must not be left
	// holding a button down.
	a.mu.Lock()
	ctl := a.ctl
	a.mu.Unlock()
	if ctl != nil {
		ctl.ReleaseAll()
	}
}

func open(ctx context.Context, kind TransportKind, port int, identityPath string) (transport.Transport, string, error) {
	switch kind {
	case TransportLAN:
		ws := transport.NewWS(port)
		return ws, ws.URL(), nil

	case TransportTunnel:
		if identityPath == "" {
			p, err := transport.DefaultIdentityPath()
			if err != nil {
				return nil, "", err
			}
			identityPath = p
		}
		id, err := transport.LoadOrCreateIdentity(identityPath)
		if err != nil {
			return nil, "", err
		}
		tc, err := transport.NewTailcat(ctx, id, transport.TailcatPort, nil)
		if err != nil {
			return nil, "", err
		}
		return tc, string(tc.Addr()), nil

	default:
		return nil, "", fmt.Errorf("unknown transport %q", kind)
	}
}

// MARK: - Settings

func (a *App) Settings() Settings {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.settings
}

// SetScroll takes effect immediately; there is no transport involvement.
func (a *App) SetScroll(gain float64, invert bool) {
	a.mu.Lock()
	a.settings.ScrollGain = gain
	a.settings.ScrollInvert = invert
	ctl := a.ctl
	a.mu.Unlock()

	if ctl != nil {
		ctl.SetScroll(cursor.ScrollConfig{Gain: gain, Invert: invert})
	}
}

// SetTransport swaps the running transport, or restarts the current one —
// which is how a failed tunnel gets retried. The phone will need to pair
// again, since the address changes, and the status reflects that.
func (a *App) SetTransport(ctx context.Context, kind TransportKind) {
	a.mu.Lock()
	a.settings.Transport = kind
	ready := a.ctl != nil
	a.mu.Unlock()

	// Before the injector is acquired there is nothing to restart; Run will
	// pick up the new setting when it gets there.
	if !ready {
		a.update(func(s *Status) { s.Transport = kind })
		return
	}

	a.stopTransport()
	a.startTransport(ctx, kind)
}

// MARK: - Status

func (a *App) Status() Status {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.status
}

// Subscribe returns a channel that receives every status change, starting
// with the current one. The channel never blocks the app: a slow reader sees
// the latest snapshot rather than a backlog.
func (a *App) Subscribe() (<-chan Status, func()) {
	ch := make(chan Status, 1)

	a.mu.Lock()
	a.subs[ch] = struct{}{}
	ch <- a.status
	a.mu.Unlock()

	return ch, func() {
		a.mu.Lock()
		delete(a.subs, ch)
		a.mu.Unlock()
	}
}

func (a *App) update(fn func(*Status)) {
	a.mu.Lock()
	fn(&a.status)
	s := a.status
	for ch := range a.subs {
		// Latest wins: drop whatever the reader hasn't taken yet.
		select {
		case <-ch:
		default:
		}
		ch <- s
	}
	a.mu.Unlock()
}

// MARK: - Transport handler

type handler struct{ app *App }

func (h *handler) OnConnect(peer string) {
	h.app.update(func(s *Status) {
		s.Phase = PhaseConnected
		s.Peer = peer
	})
}

func (h *handler) OnMessage(m proto.Msg) {
	h.app.mu.Lock()
	ctl := h.app.ctl
	h.app.mu.Unlock()
	if ctl == nil {
		return
	}

	var err error
	switch m.T {
	case proto.KindMove:
		err = ctl.Move(m.DX, m.DY, m.DT)
	case proto.KindScroll:
		err = ctl.Scroll(m.DX, m.DY)
	case proto.KindClick:
		err = ctl.Button(button(m.B), m.D)
	default:
		err = fmt.Errorf("unknown kind %q", m.T)
	}
	if err != nil {
		log.Printf("handle %q: %v", m.T, err)
	}
}

func (h *handler) OnDisconnect() {
	h.app.mu.Lock()
	ctl := h.app.ctl
	h.app.mu.Unlock()
	if ctl != nil {
		ctl.ReleaseAll()
	}
	h.app.update(func(s *Status) {
		if s.Phase == PhaseConnected {
			s.Phase = PhaseListening
		}
		s.Peer = ""
	})
}

func button(b string) inject.Button {
	switch b {
	case proto.ButtonRight:
		return inject.ButtonRight
	case proto.ButtonMiddle:
		return inject.ButtonMiddle
	default:
		return inject.ButtonLeft
	}
}
