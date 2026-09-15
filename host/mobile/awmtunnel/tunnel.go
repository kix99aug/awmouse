// Package awmtunnel is the phone's end of the tailcat pipe, shaped for
// gomobile: only strings, integers, errors and plain interfaces cross the
// boundary. It is bound into a framework (see ios/Makefile) and the Swift
// client calls it in place of a socket.
//
// The Swift side keeps building JSON exactly as it does for the WebSocket
// path; this package only carries the bytes. Nothing here knows the protocol.
package awmtunnel

import (
	"context"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"

	"github.com/tailscale/tailcat"
	"tailscale.com/types/key"
)

// Port must match transport.TailcatPort on the host. It is duplicated rather
// than imported so that the bound framework does not drag the host's
// injection packages along with it.
const Port = 8787

// NewKey returns a fresh client identity. The phone should persist it (in the
// Keychain) and pass the same key to every Dial, so the host can recognise
// the phone across sessions and eventually allow-list it.
func NewKey() string {
	b, _ := key.NewNode().MarshalText()
	return string(b)
}

// Listener receives the one event the phone cannot poll for: the tunnel
// closing underneath it. Called at most once, from a background goroutine.
type Listener interface {
	OnClosed(reason string)
}

// Session is one connection to the host.
type Session struct {
	client *tailcat.Client
	conn   net.Conn

	mu     sync.Mutex
	closed bool
}

// Dial connects to the host at addr — the tailcat address from the QR code —
// identifying as clientKey (from NewKey; empty for an ephemeral identity).
// timeoutMillis bounds the whole bootstrap: relay connection, WireGuard
// handshake, and the TCP connect inside the tunnel.
func Dial(addr, clientKey string, timeoutMillis int64, l Listener) (*Session, error) {
	c := &tailcat.Client{
		Server: tailcat.Addr(addr),
		Logf:   func(string, ...any) {},
	}
	if clientKey != "" {
		if err := c.Key.UnmarshalText([]byte(clientKey)); err != nil {
			return nil, fmt.Errorf("client key: %w", err)
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMillis)*time.Millisecond)
	defer cancel()

	conn, err := c.DialTCPPort(ctx, Port)
	if err != nil {
		c.Close()
		return nil, err
	}

	s := &Session{client: c, conn: conn}
	go s.watch(l)
	return s, nil
}

// watch drains the connection. The host never sends anything, so the first
// thing read is EOF or an error — either way the tunnel is gone.
func (s *Session) watch(l Listener) {
	buf := make([]byte, 256)
	var err error
	for {
		if _, err = s.conn.Read(buf); err != nil {
			break
		}
	}
	s.mu.Lock()
	wasClosed := s.closed
	s.closed = true
	s.mu.Unlock()
	if !wasClosed && l != nil {
		reason := err.Error()
		if errors.Is(err, net.ErrClosed) {
			reason = "closed"
		}
		l.OnClosed(reason)
	}
}

// Send writes one JSON message. The framing is one message per line, so the
// message must not contain a newline — Swift's JSONEncoder never emits one
// unless asked to pretty-print.
func (s *Session) Send(json string) error {
	s.mu.Lock()
	closed := s.closed
	s.mu.Unlock()
	if closed {
		return net.ErrClosed
	}
	_, err := s.conn.Write(append([]byte(json), '\n'))
	return err
}

// Ping measures the round trip to the host over the tunnel's discovery
// channel and returns it in milliseconds. It is also the phone's liveness
// check: a host that crashed sends no FIN, and a write into the in-process
// TCP stack succeeds locally whether or not anyone is listening, so Send
// alone cannot tell a dead host from a quiet one.
func (s *Session) Ping(timeoutMillis int64) (int64, error) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMillis)*time.Millisecond)
	defer cancel()
	r, err := s.client.Ping(ctx)
	if err != nil {
		return 0, err
	}
	return r.Latency.Milliseconds(), nil
}

// Close tears down the connection and the tunnel behind it.
func (s *Session) Close() error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil
	}
	s.closed = true
	s.mu.Unlock()
	s.conn.Close()
	return s.client.Close()
}
