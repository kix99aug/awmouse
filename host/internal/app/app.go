// Package app wires the injector, cursor controller, and transport together
// and exposes their combined state, so that a user interface only has to
// render it.
//
// Everything that used to live in the daemon's main() is here, plus what a
// window needs and a terminal never did: settings that change without a
// restart, a transport that can be restarted, and a permission gate that waits
// instead of exiting.
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

// The one transport is tailcat: end-to-end encrypted, reachable from any
// network, brokered through a relay only until a direct path exists — which
// on the same LAN it finds at once, so a separate local-network transport
// would add a choice without adding a capability.
type Settings struct {
	IdentityPath string // tailcat identity file; empty means the per-user default
	PairedPath   string // paired-device list; empty means beside the identity
	ScrollGain   float64
	ScrollInvert bool
}

func DefaultSettings() Settings {
	return Settings{ScrollGain: cursor.DefaultScroll.Gain}
}

type Phase int

const (
	// PhaseNeedsPermission: the OS will not let us post input yet. macOS only
	// in practice — Accessibility must be granted in System Settings, and the
	// app keeps checking until it is.
	PhaseNeedsPermission Phase = iota
	// PhaseStarting: the tunnel is coming up, which takes a second or two
	// while the nearest relay is measured.
	PhaseStarting
	// PhaseListening: ready, nothing connected.
	PhaseListening
	// PhaseConnected: a phone is driving the cursor.
	PhaseConnected
	// PhaseFailed: the tunnel could not start. Error says why. The app stays
	// up so the user can retry once the cause — usually no network — is fixed.
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
	Phase Phase
	// Endpoint is the QR payload — the deep link the phone opens. It carries
	// the current pairing code, so it changes whenever the code does.
	Endpoint string
	// Address is the human-readable form for typing in by hand. Stable.
	Address string
	// Code is the pairing code, shown so it can be typed when the address
	// was pasted rather than scanned. Rotates on every pairing and on expiry.
	Code        string
	CodeExpires time.Time
	Devices     []Device
	Peer        string
	Error       string
}

type App struct {
	mu       sync.Mutex
	settings Settings
	status   Status
	subs     map[chan Status]struct{}

	inj  inject.Injector
	ctl  *cursor.Controller
	pair *pairing

	// endpointBase is the transport's deep link without the code; the code
	// is appended at publish time so the QR follows rotations.
	endpointBase string

	// Live connections by peer, so that forgetting a device can also drop it
	// if it happens to be connected right now.
	conns map[string]transport.Conn

	// The running transport, if any. Restarting cancels the old context and
	// waits on done before starting again, so two listeners never fight over
	// the identity file.
	cancelTransport context.CancelFunc
	transportDone   chan struct{}
}

func New(s Settings) (*App, error) {
	path := s.PairedPath
	if path == "" {
		p, err := DefaultPairedPath()
		if err != nil {
			return nil, err
		}
		path = p
	}
	pair, err := newPairing(path)
	if err != nil {
		return nil, err
	}

	a := &App{
		settings: s,
		status:   Status{Phase: PhaseStarting},
		subs:     map[chan Status]struct{}{},
		pair:     pair,
		conns:    map[string]transport.Conn{},
	}
	a.refreshPairing()
	return a, nil
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
	a.mu.Unlock()

	a.startTransport(ctx)

	// The code expires on its own; make sure the window learns of it without
	// anyone connecting.
	go a.tickPairing(ctx)

	<-ctx.Done()
	a.stopTransport()
	return nil
}

// tickPairing checks once a second whether the code has rolled over, and
// publishes only when it has. The window keeps its own countdown; the app
// need not chatter every second to drive it.
func (a *App) tickPairing(ctx context.Context) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			code, _ := a.pair.Code() // rotates if expired
			a.mu.Lock()
			changed := code != a.status.Code
			a.mu.Unlock()
			if changed {
				a.refreshPairing()
			}
		}
	}
}

// refreshPairing publishes the current code, its expiry, and the device
// list. Reading the code rotates it if it has expired, so this is also what
// keeps a stale code from ever being displayed.
func (a *App) refreshPairing() {
	code, expires := a.pair.Code()
	devices := a.pair.Devices()
	a.mu.Lock()
	base := a.endpointBase
	a.mu.Unlock()
	a.update(func(s *Status) {
		s.Code, s.CodeExpires, s.Devices = code, expires, devices
		s.Endpoint = endpointWithCode(base, code)
	})
}

func endpointWithCode(base, code string) string {
	if base == "" {
		return ""
	}
	return base + "&code=" + code
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

// startTransport brings up the tunnel in the background. Must not be called
// while one is running; use Restart for that.
func (a *App) startTransport(parent context.Context) {
	ctx, cancel := context.WithCancel(parent)
	done := make(chan struct{})

	a.mu.Lock()
	a.cancelTransport = cancel
	a.transportDone = done
	identity := a.settings.IdentityPath
	a.mu.Unlock()

	a.mu.Lock()
	a.endpointBase = ""
	a.mu.Unlock()
	a.update(func(s *Status) {
		s.Phase = PhaseStarting
		s.Endpoint, s.Address, s.Peer, s.Error = "", "", "", ""
	})

	go func() {
		defer close(done)

		tr, address, err := open(ctx, identity)
		if err != nil {
			if ctx.Err() != nil {
				return // cancelled mid-start; not a failure worth showing
			}
			log.Printf("tunnel: %v", err)
			a.update(func(s *Status) {
				s.Phase = PhaseFailed
				s.Error = err.Error()
			})
			return
		}

		a.mu.Lock()
		a.endpointBase = tr.Endpoint()
		a.mu.Unlock()
		a.update(func(s *Status) {
			s.Phase = PhaseListening
			s.Address = address
		})
		a.refreshPairing()

		if err := tr.Run(ctx, &handler{app: a}); err != nil && ctx.Err() == nil {
			log.Printf("tunnel: %v", err)
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

func open(ctx context.Context, identityPath string) (transport.Transport, string, error) {
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

// Restart tears the tunnel down and brings it up again — how a start that
// failed for want of a network gets retried. The identity is the same, so the
// address is too, and a phone that already paired stays paired.
func (a *App) Restart(ctx context.Context) {
	a.mu.Lock()
	ready := a.ctl != nil
	a.mu.Unlock()

	// Before the injector is acquired there is nothing to restart; Run will
	// bring the tunnel up when it gets there.
	if !ready {
		return
	}

	a.stopTransport()
	a.startTransport(ctx)
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

// MARK: - Devices

// Forget revokes a paired phone. If it is connected right now it is dropped
// too; a revocation that only takes effect next time is not a revocation.
func (a *App) Forget(id string) error {
	if err := a.pair.Forget(id); err != nil {
		return err
	}
	a.mu.Lock()
	c := a.conns[id]
	a.mu.Unlock()
	if c != nil {
		_ = c.Close()
	}
	a.refreshPairing()
	return nil
}

// MARK: - Transport handler

// handler admits connections. Accept produces a session per connection;
// the session is what knows whether this phone has said hello yet.
type handler struct{ app *App }

func (h *handler) Accept(peer string, c transport.Conn) transport.Session {
	a := h.app
	a.mu.Lock()
	// A second connection from the same device replaces the first — the
	// phone reconnected without the host noticing the old one die.
	if old := a.conns[peer]; old != nil {
		_ = old.Close()
	}
	a.conns[peer] = c
	a.mu.Unlock()

	return &session{app: a, peer: peer, conn: c, paired: a.pair.IsPaired(peer)}
}

type session struct {
	app  *App
	peer string
	conn transport.Conn

	// paired: admitted. Set on Accept for a known device, or after a hello
	// with the right code. Until then only a hello is acceptable.
	paired  bool
	greeted bool
}

func (s *session) OnMessage(m proto.Msg) error {
	if !s.greeted {
		return s.hello(m)
	}
	if !s.paired {
		// Cannot happen: a failed hello ends the connection. Belt and braces.
		return fmt.Errorf("unpaired peer sent %q", m.T)
	}

	s.app.mu.Lock()
	ctl := s.app.ctl
	s.app.mu.Unlock()
	if ctl == nil {
		return nil
	}

	var err error
	switch m.T {
	case proto.KindMove:
		err = ctl.Move(m.DX, m.DY, m.DT)
	case proto.KindScroll:
		err = ctl.Scroll(m.DX, m.DY)
	case proto.KindClick:
		err = ctl.Button(button(m.B), m.D)
	case proto.KindHello:
		// Harmless repeat; answer it so a client that retries is not left
		// waiting.
		return s.conn.Reply(proto.Msg{T: proto.KindOK})
	default:
		err = fmt.Errorf("unknown kind %q", m.T)
	}
	if err != nil {
		log.Printf("handle %q: %v", m.T, err)
	}
	return nil
}

// hello resolves the first message. A known device is admitted whatever
// code it sent; an unknown one must present the current code. Either way
// exactly one reply goes back, and a refusal ends the connection.
func (s *session) hello(m proto.Msg) error {
	s.greeted = true

	if m.T != proto.KindHello {
		_ = s.conn.Reply(proto.Msg{T: proto.KindNo, Reason: proto.ReasonHello})
		return fmt.Errorf("first message was %q, not hello", m.T)
	}

	if !s.paired {
		switch err := s.app.pair.Try(s.peer, m.Name, m.Code); {
		case err == nil:
			s.paired = true
			log.Printf("paired new device %q (%s)", m.Name, s.peer)
			s.app.refreshPairing()
		case errors.Is(err, errLocked):
			_ = s.conn.Reply(proto.Msg{T: proto.KindNo, Reason: proto.ReasonLocked})
			return err
		default:
			_ = s.conn.Reply(proto.Msg{T: proto.KindNo, Reason: proto.ReasonCode})
			return err
		}
	}

	if err := s.conn.Reply(proto.Msg{T: proto.KindOK}); err != nil {
		return err
	}
	s.app.update(func(st *Status) {
		st.Phase = PhaseConnected
		st.Peer = s.peer
	})
	return nil
}

func (s *session) OnDisconnect() {
	a := s.app

	a.mu.Lock()
	if a.conns[s.peer] == s.conn {
		delete(a.conns, s.peer)
	}
	ctl := a.ctl
	a.mu.Unlock()

	if ctl != nil {
		ctl.ReleaseAll()
	}
	if s.paired {
		a.update(func(st *Status) {
			if st.Phase == PhaseConnected && st.Peer == s.peer {
				st.Phase = PhaseListening
				st.Peer = ""
			}
		})
	}
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
