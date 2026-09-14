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
	port := flag.Int("port", 8787, "listen port")
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

	ws := transport.NewWS(*port)
	printPairing(ws)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := ws.Run(ctx, &handler{ctl: ctl}); err != nil {
		log.Fatalf("transport: %v", err)
	}
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

func printPairing(ws *transport.WS) {
	fmt.Println()
	qrterminal.GenerateHalfBlock(ws.Endpoint(), qrterminal.L, os.Stdout)
	fmt.Printf("\n  scan the code, or enter this manually:\n\n      %s\n\n", ws.URL())
}
