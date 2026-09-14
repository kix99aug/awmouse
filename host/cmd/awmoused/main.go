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

	ctl := cursor.New(inj, cursor.DefaultCurve)

	ws := transport.NewWS(*port)
	printPairing(ws)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	err = ws.Run(ctx, func(m proto.Msg) {
		if err := handle(ctl, m); err != nil {
			log.Printf("handle %q: %v", m.T, err)
		}
	})
	if err != nil {
		log.Fatalf("transport: %v", err)
	}
}

func handle(ctl *cursor.Controller, m proto.Msg) error {
	switch m.T {
	case proto.KindMove:
		return ctl.Move(m.DX, m.DY, m.DT)
	case proto.KindClick:
		b := inject.ButtonLeft
		if m.B == proto.ButtonRight {
			b = inject.ButtonRight
		}
		return ctl.Button(b, m.D)
	case proto.KindScroll:
		return nil // reserved
	default:
		return fmt.Errorf("unknown kind")
	}
}

func printPairing(ws *transport.WS) {
	fmt.Println()
	qrterminal.GenerateHalfBlock(ws.Endpoint(), qrterminal.L, os.Stdout)
	fmt.Printf("\n  scan the code, or enter this manually:\n\n      %s\n\n", ws.URL())
}
