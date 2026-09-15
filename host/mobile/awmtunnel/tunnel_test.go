package awmtunnel_test

import (
	"context"
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

	"awmouse/host/internal/proto"
	"awmouse/host/internal/transport"
	"awmouse/host/mobile/awmtunnel"
)

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
func (r *recorder) OnDisconnect() { close(r.disconnected) }

type closeWatcher struct{ closed chan string }

func (w *closeWatcher) OnClosed(reason string) { w.closed <- reason }

// TestPhoneToHost is the phone's half of the pipe against the host's half,
// over a loopback relay: what the Swift client will do, minus gomobile.
func TestPhoneToHost(t *testing.T) {
	dm := integration.RunDERPAndSTUN(t, func(string, ...any) {}, "127.0.0.1")
	reg := dm.Regions[1]

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	id := transport.Identity{Key: key.NewNode(), PSK: tailcat.NewPresharedKey()}
	host, err := transport.NewTailcat(ctx, id, transport.TailcatPort, reg)
	if err != nil {
		t.Fatalf("host: %v", err)
	}

	rec := &recorder{disconnected: make(chan struct{})}
	go host.Run(ctx, rec)

	clientKey := awmtunnel.NewKey()
	if err := new(key.NodePrivate).UnmarshalText([]byte(clientKey)); err != nil {
		t.Fatalf("NewKey() = %q, not a node key: %v", clientKey, err)
	}

	w := &closeWatcher{closed: make(chan string, 1)}
	s, err := awmtunnel.Dial(string(host.Addr()), clientKey, 15000, w)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}

	if ms, err := s.Ping(5000); err != nil {
		t.Errorf("Ping: %v", err)
	} else {
		t.Logf("ping %d ms", ms)
	}

	if err := s.Send(`{"t":"c","b":"r","d":true}`); err != nil {
		t.Fatalf("Send: %v", err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		rec.mu.Lock()
		n := len(rec.msgs)
		rec.mu.Unlock()
		if n == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("host never received the message")
		}
		time.Sleep(20 * time.Millisecond)
	}
	rec.mu.Lock()
	got := rec.msgs[0]
	rec.mu.Unlock()
	if want := (proto.Msg{T: proto.KindClick, B: proto.ButtonRight, D: true}); got != want {
		t.Errorf("host got %+v, want %+v", got, want)
	}

	// Host goes away: the phone must hear about it, and a later Send must
	// fail rather than silently vanish.
	cancel()
	select {
	case reason := <-w.closed:
		t.Logf("OnClosed(%q)", reason)
	case <-time.After(10 * time.Second):
		t.Fatal("OnClosed not called after host shut down")
	}
	if err := s.Send(`{"t":"c","b":"r","d":false}`); err == nil {
		t.Error("Send after close succeeded")
	}
	if err := s.Close(); err != nil {
		t.Errorf("Close: %v", err)
	}
}
