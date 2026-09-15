package transport

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"sync"
	"time"

	"github.com/tailscale/tailcat"
	"tailscale.com/tailcfg"

	"awmouse/host/internal/proto"
)

// Tailcat serves the protocol over a tailcat pipe: WireGuard between the two
// ends, NAT traversal by magicsock, and a DERP relay only until a direct path
// is found. There is no control plane and no account — the address the phone
// scans is the whole bootstrap.
//
// Framing is newline-delimited JSON on a single TCP stream. WebSocket bought
// nothing here: on this path the phone speaks through an in-process Go
// client, so there is no platform socket API to accommodate.
type Tailcat struct {
	port uint16
	srv  *tailcat.Server
	addr tailcat.Addr

	// Set by Run. tailcat's accept hook is registered before Start, when
	// there is no handler yet, so it looks these up per connection.
	mu      sync.Mutex
	handler Handler
	ctx     context.Context
}

// TailcatPort is the port the host listens on inside the tunnel. It is
// unrelated to any port on the machine's real interfaces; nothing needs to
// be opened in a firewall.
const TailcatPort = 8787

// NewTailcat starts the tunnel endpoint and resolves the host's address.
// Starting is a network operation — it fetches the DERP map and measures the
// nearest region — which is why this is separate from Run: the QR code needs
// the address before anything is served.
//
// region overrides the relay; nil picks the nearest from the public map.
// Tests pass a loopback relay so they run offline.
func NewTailcat(ctx context.Context, id Identity, port uint16, region *tailcfg.DERPRegion) (*Tailcat, error) {
	t := &Tailcat{
		port: port,
		srv: &tailcat.Server{
			Key:          id.Key,
			PresharedKey: id.PSK,
			Region:       region,
			Logf:         func(string, ...any) {}, // tailcat is chatty at the level of individual DERP frames
		},
	}
	t.srv.OnTCP = func(port uint16) func(net.Conn) {
		if port != t.port {
			return nil // RST
		}
		return t.accept
	}
	if err := t.srv.Start(); err != nil {
		return nil, fmt.Errorf("tailcat: %w", err)
	}
	t.addr = t.srv.TailcatAddr()
	return t, nil
}

// Addr is the tailcat address: the host's public keys, the pre-shared key,
// and its DERP region, base64url-encoded. It is a secret — holding it means
// being able to connect.
func (t *Tailcat) Addr() tailcat.Addr { return t.addr }

// Endpoint is the deep link the QR code encodes. It carries the tailcat
// address rather than any IP, so the same code works from any network.
func (t *Tailcat) Endpoint() string {
	return "awmouse://pair?tc=" + string(t.addr)
}

// Run serves connections until ctx is cancelled. The tunnel is already up
// from NewTailcat; a connection arriving before Run is refused.
func (t *Tailcat) Run(ctx context.Context, h Handler) error {
	t.mu.Lock()
	t.handler, t.ctx = h, ctx
	t.mu.Unlock()

	<-ctx.Done()

	t.mu.Lock()
	t.handler, t.ctx = nil, nil
	t.mu.Unlock()

	// The TCP stack lives in this process: closing the engine straight after
	// the connections drops their FINs on the floor, and the phone sits on a
	// dead link that looks open. Give the stack a moment to get them out.
	// The bound is generous for a FIN and short for a Ctrl-C.
	drainCtx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_ = t.srv.DrainTCP(drainCtx)
	return t.srv.Close()
}

// accept runs on tailcat's per-connection goroutine.
func (t *Tailcat) accept(c net.Conn) {
	t.mu.Lock()
	h, ctx := t.handler, t.ctx
	t.mu.Unlock()
	if h == nil {
		c.Close()
		return
	}
	t.serve(ctx, c, h)
}

func (t *Tailcat) serve(ctx context.Context, c net.Conn, h Handler) {
	defer c.Close()

	// Close the connection when the server shuts down, so a blocked read in
	// the scanner below unblocks and the disconnect handler runs.
	stop := context.AfterFunc(ctx, func() { c.Close() })
	defer stop()

	peer := c.RemoteAddr().String()
	log.Printf("client connected: %s", peer)

	sess := h.Accept(peer, lineConn{c})
	if sess == nil {
		log.Printf("client refused: %s", peer)
		return
	}
	defer func() {
		sess.OnDisconnect()
		log.Printf("client disconnected: %s", peer)
	}()

	sc := bufio.NewScanner(c)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		if err := dispatch(sess, line); err != nil {
			log.Printf("client %s: %v", peer, err)
			return
		}
	}
}

// lineConn adapts a net.Conn to the newline-delimited JSON the phone reads.
type lineConn struct{ net.Conn }

func (l lineConn) Reply(m proto.Msg) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	_, err = l.Write(append(b, '\n'))
	return err
}
