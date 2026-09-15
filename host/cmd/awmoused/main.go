// Command awmoused receives pointer input from the awmouse phone client and
// injects it as real cursor events.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/mdp/qrterminal/v3"

	"awmouse/host/internal/cursor"
	"awmouse/host/internal/inject"
	"awmouse/host/internal/proto"
	"awmouse/host/internal/transport"
)

func main() {
	mode := flag.String("transport", "ws", "transport: ws (LAN WebSocket) or tailcat")
	port := flag.Int("port", 8787, "listen port (ws transport)")
	identityPath := flag.String("identity", "", "tailcat identity file (default: per-user config dir)")
	scrollGain := flag.Float64("scroll-gain", cursor.DefaultScroll.Gain, "scroll sensitivity")
	scrollInvert := flag.Bool("scroll-invert", false, "reverse scroll direction")
	flag.Parse()

	log.SetFlags(log.Ltime)

	inj, err := inject.New()
	if err != nil {
		if errors.Is(err, inject.ErrNotTrusted) {
			fmt.Fprintf(os.Stderr, "\n%v\n\n", err)
			os.Exit(1)
		}
		log.Fatalf("injector: %v", err)
	}
	defer inj.Close()

	ctl := cursor.New(inj, cursor.DefaultCurve, cursor.ScrollConfig{
		Gain:   *scrollGain,
		Invert: *scrollInvert,
	})

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var tr transport.Transport
	var manual string
	switch *mode {
	case "ws":
		ws := transport.NewWS(*port)
		tr, manual = ws, ws.URL()
	case "tailcat":
		tc, err := startTailcat(ctx, *identityPath)
		if err != nil {
			log.Fatalf("tailcat: %v", err)
		}
		tr, manual = tc, string(tc.Addr())
	default:
		log.Fatalf("unknown -transport %q", *mode)
	}
	printPairing(tr, manual)

	if err := tr.Run(ctx, &handler{ctl: ctl}); err != nil {
		log.Fatalf("transport: %v", err)
	}
}

func startTailcat(ctx context.Context, identityPath string) (*transport.Tailcat, error) {
	if identityPath == "" {
		p, err := transport.DefaultIdentityPath()
		if err != nil {
			return nil, err
		}
		identityPath = p
	}
	id, err := transport.LoadOrCreateIdentity(identityPath)
	if err != nil {
		return nil, err
	}
	log.Printf("identity: %s", identityPath)
	log.Printf("connecting to relay...")
	return transport.NewTailcat(ctx, id, transport.TailcatPort, nil)
}

type handler struct {
	ctl *cursor.Controller
}

func (h *handler) OnMessage(m proto.Msg) {
	var err error
	switch m.T {
	case proto.KindMove:
		err = h.ctl.Move(m.DX, m.DY, m.DT)
	case proto.KindScroll:
		err = h.ctl.Scroll(m.DX, m.DY)
	case proto.KindClick:
		err = h.ctl.Button(button(m.B), m.D)
	default:
		err = fmt.Errorf("unknown kind %q", m.T)
	}
	if err != nil {
		log.Printf("handle %q: %v", m.T, err)
	}
}

func (h *handler) OnDisconnect() {
	h.ctl.ReleaseAll()
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

func printPairing(tr transport.Transport, manual string) {
	fmt.Println()
	qrterminal.GenerateHalfBlock(tr.Endpoint(), qrterminal.L, os.Stdout)
	fmt.Printf("\n  scan the code, or enter this manually:\n\n      %s\n\n", manual)
}
