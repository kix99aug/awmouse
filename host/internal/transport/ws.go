package transport

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"time"

	"github.com/coder/websocket"
)

// WS is the POC transport: a plain WebSocket server on the local network.
type WS struct {
	port int
	ip   string
}

func NewWS(port int) *WS {
	return &WS{port: port, ip: localIP()}
}

func (w *WS) URL() string {
	return fmt.Sprintf("ws://%s:%d/ws", w.ip, w.port)
}

// Endpoint is a deep link so that scanning the QR with the stock Camera app
// opens the app directly, rather than requiring the user to find the in-app
// scanner first.
func (w *WS) Endpoint() string {
	return "awmouse://pair?ws=" + w.URL()
}

func (w *WS) Run(ctx context.Context, h Handler) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", func(rw http.ResponseWriter, r *http.Request) {
		// The iOS client sends no Origin header, so the default same-origin
		// check would reject it.
		c, err := websocket.Accept(rw, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			log.Printf("accept: %v", err)
			return
		}
		defer c.CloseNow()

		log.Printf("client connected: %s", r.RemoteAddr)
		h.OnConnect(r.RemoteAddr)
		defer func() {
			h.OnDisconnect()
			log.Printf("client disconnected: %s", r.RemoteAddr)
		}()

		for {
			_, data, err := c.Read(ctx)
			if err != nil {
				return
			}
			dispatch(h, data)
		}
	})

	srv := &http.Server{
		Addr:              fmt.Sprintf(":%d", w.port),
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return err
	}
	return nil
}

// localIP finds the address this machine uses to reach the LAN. The UDP dial
// sends no packets; it just asks the routing table which interface would be
// chosen.
func localIP() string {
	conn, err := net.Dial("udp", "8.8.8.8:80")
	if err != nil {
		return "127.0.0.1"
	}
	defer conn.Close()
	return conn.LocalAddr().(*net.UDPAddr).IP.String()
}
