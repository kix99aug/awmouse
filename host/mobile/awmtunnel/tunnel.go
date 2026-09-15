// Package awmtunnel is the phone's end of the tailcat pipe, shaped for
// gomobile: only strings, integers, errors and plain interfaces cross the
// boundary. It is bound into a framework (see ios/Makefile) and the Swift
// client calls it in place of a socket.
//
// The Swift side builds the JSON; this package carries the bytes. The one
// exception is Hello, which knows just enough of the protocol to ask the host
// to admit this phone and to read its one-line answer.
package awmtunnel

import (
	"bufio"
	"context"
	"encoding/json"
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

	// The host writes exactly one line, in answer to Hello. watch is the
	// connection's only reader and hands that line over here; a second
	// reader would race it for the bytes.
	lines chan string

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

	s := &Session{client: c, conn: conn, lines: make(chan string, 1)}
	go s.watch(l)
	return s, nil
}

// Hello asks the host to admit this phone. code is the pairing code from the
// host's QR or window; a phone the host already knows is admitted whatever it
// sends, so pass whatever is on hand. name is shown in the host's device list.
//
// A refusal is a result, not an error: the host answered, and said no, and
// its reason is one the app can act on — ask for a code, or wait. The error
// return is for the transport failing to get an answer at all.
func (s *Session) Hello(code, name string, timeoutMillis int64) (*HelloResult, error) {
	req, err := json.Marshal(map[string]string{"t": "h", "code": code, "name": name})
	if err != nil {
		return nil, err
	}
	if err := s.Send(string(req)); err != nil {
		return nil, err
	}

	select {
	case line, ok := <-s.lines:
		if !ok {
			return nil, errors.New("host closed the connection")
		}
		var reply struct {
			T      string `json:"t"`
			Reason string `json:"reason"`
		}
		if err := json.Unmarshal([]byte(line), &reply); err != nil {
			return nil, fmt.Errorf("host answered with something unreadable: %w", err)
		}
		switch reply.T {
		case "ok":
			return &HelloResult{Admitted: true}, nil
		case "no":
			return &HelloResult{Reason: reply.Reason}, nil
		default:
			return nil, fmt.Errorf("host answered %q, expected ok or no", reply.T)
		}
	case <-time.After(time.Duration(timeoutMillis) * time.Millisecond):
		return nil, errors.New("host did not answer")
	}
}

// HelloResult is the host's answer. When Admitted is false, Reason says why —
// one of the Reason* constants, or empty if the host gave none.
type HelloResult struct {
	Admitted bool
	Reason   string
}

// Reasons the host may give. Duplicated from the host's proto package for
// the same reason Port is: the framework must not import host internals.
const (
	ReasonCode   = "code"
	ReasonLocked = "locked"
	ReasonHello  = "hello"
)

func (s *Session) watch(l Listener) {
	// Lines are handed to Hello; anything beyond the one the host sends is
	// dropped, since the protocol is otherwise one-way. Reading is what
	// notices the connection ending.
	sc := bufio.NewScanner(s.conn)
	for sc.Scan() {
		select {
		case s.lines <- sc.Text():
		default:
		}
	}
	err := sc.Err()
	close(s.lines)

	s.mu.Lock()
	wasClosed := s.closed
	s.closed = true
	s.mu.Unlock()
	if !wasClosed && l != nil {
		reason := "closed"
		if err != nil && !errors.Is(err, net.ErrClosed) {
			reason = err.Error()
		}
		l.OnClosed(reason)
	}
}

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

func (s *Session) Ping(timeoutMillis int64) (int64, error) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMillis)*time.Millisecond)
	defer cancel()
	r, err := s.client.Ping(ctx)
	if err != nil {
		return 0, err
	}
	return r.Latency.Milliseconds(), nil
}

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
