package transport

import (
	"context"
	"fmt"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/tailscale/tailcat"
	"tailscale.com/envknob"
	"tailscale.com/net/netcheck"
	"tailscale.com/syncs"
	"tailscale.com/tailcfg"
	"tailscale.com/tstest/integration"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"

	"awmouse/host/internal/proto"
)

// The same two knobs tailcat's own tests set: skip the portmapper's gateway
// probe and captive-portal detection, both of which netcheck otherwise
// blocks on for over a second per engine start.
func TestMain(m *testing.M) {
	envknob.Setenv("IN_TS_TEST", "true")
	netcheck.HookStartCaptivePortalDetection.SetForTest(func(context.Context, *netcheck.Client, *tailcfg.DERPMap, tailcfg.DERPRegionID, func(bool)) (<-chan struct{}, func()) {
		return syncs.ClosedChan(), func() {}
	})
	os.Exit(m.Run())
}

type recorder struct {
	mu           sync.Mutex
	msgs         []proto.Msg
	disconnected chan struct{}
}

func (r *recorder) OnMessage(m proto.Msg) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.msgs = append(r.msgs, m)
}

func (r *recorder) OnConnect(string) {}
func (r *recorder) OnDisconnect()    { close(r.disconnected) }

func (r *recorder) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.msgs)
}

// TestTailcatEndToEnd runs the host transport and a tailcat client against a
// loopback DERP, so it exercises the real tunnel with no network access.
func TestTailcatEndToEnd(t *testing.T) {
	dm := integration.RunDERPAndSTUN(t, quietLogf, "127.0.0.1")
	reg := dm.Regions[1]
	if reg == nil {
		t.Fatal("no region 1 in local DERP map")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	id := Identity{Key: key.NewNode(), PSK: tailcat.NewPresharedKey()}
	tc, err := NewTailcat(ctx, id, TailcatPort, reg)
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if got, want := tc.Endpoint(), "awmouse://pair?tc="+string(tc.Addr()); got != want {
		t.Errorf("Endpoint() = %q, want %q", got, want)
	}

	rec := &recorder{disconnected: make(chan struct{})}
	runCtx, stopRun := context.WithCancel(ctx)
	runDone := make(chan error, 1)
	go func() { runDone <- tc.Run(runCtx, rec) }()

	c := &tailcat.Client{Server: tc.Addr(), Logf: quietLogf}
	defer c.Close()

	// A successful ping means the server has added us as a peer and a dial
	// will not be dropped on the floor.
	if _, err := c.Ping(ctx); err != nil {
		t.Fatalf("ping: %v", err)
	}

	conn, err := c.DialTCPPort(ctx, TailcatPort)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}

	lines := []string{
		`{"t":"m","dx":12.5,"dy":-4,"dt":33}`,
		`{"t":"c","b":"l","d":true}`,
		`not json`,
		`{"t":"c","b":"l","d":false}`,
	}
	for _, l := range lines {
		if _, err := fmt.Fprintln(conn, l); err != nil {
			t.Fatalf("write: %v", err)
		}
	}
	waitFor(t, func() bool { return rec.count() == 3 }, "3 messages")

	want := []proto.Msg{
		{T: proto.KindMove, DX: 12.5, DY: -4, DT: 33},
		{T: proto.KindClick, B: proto.ButtonLeft, D: true},
		{T: proto.KindClick, B: proto.ButtonLeft, D: false},
	}
	rec.mu.Lock()
	for i, m := range rec.msgs {
		if m != want[i] {
			t.Errorf("msg %d = %+v, want %+v", i, m, want[i])
		}
	}
	rec.mu.Unlock()

	// Losing the client mid-drag must reach the handler, whichever way the
	// connection ends.
	conn.Close()
	select {
	case <-rec.disconnected:
	case <-time.After(10 * time.Second):
		t.Fatal("OnDisconnect not called after client closed")
	}

	stopRun()
	select {
	case err := <-runDone:
		if err != nil {
			t.Errorf("Run: %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Run did not return after cancel")
	}
}

func waitFor(t *testing.T, cond func() bool, what string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func quietLogf(string, ...any) {}

var _ logger.Logf = quietLogf
