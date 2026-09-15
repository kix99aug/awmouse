// Command awmouse is the host: it receives pointer input from the phone and
// moves the real cursor. It lives in the system tray, and its one window
// shows the pairing code, the connection state, and the few settings there
// are.
package main

import (
	"context"
	"log"

	"fyne.io/fyne/v2"
	fyneapp "fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/driver/desktop"
	"fyne.io/fyne/v2/theme"

	"awmouse/host/internal/app"
	"awmouse/host/internal/assets"
)

const appID = "space.keybo.awmouse.host"

func main() {
	log.SetFlags(log.Ltime)

	fa := fyneapp.NewWithID(appID)
	fa.SetIcon(assets.Icon)

	core := app.New(loadSettings(fa.Preferences()))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		if err := core.Run(ctx); err != nil && ctx.Err() == nil {
			log.Printf("app: %v", err)
		}
	}()

	w := fa.NewWindow("awmouse")
	v := newView(ctx, fa, core)
	w.SetContent(v.root)
	w.Resize(fyne.NewSize(380, 620))
	w.SetFixedSize(true)

	// Closing the window hides it; the app keeps running in the tray, which is
	// where Quit lives. A remote mouse that exits when its window closes is
	// not much of a remote mouse.
	w.SetCloseIntercept(w.Hide)

	if desk, ok := fa.(desktop.App); ok {
		// ThemedResource is what makes Fyne register the icon as a template
		// image on macOS, so the menu bar recolours it for light and dark.
		desk.SetSystemTrayIcon(theme.NewThemedResource(assets.Tray))
		desk.SetSystemTrayMenu(fyne.NewMenu("awmouse",
			fyne.NewMenuItem("Show awmouse", func() {
				w.Show()
				w.RequestFocus()
			}),
		))
	}

	go v.follow(core)

	w.ShowAndRun()
}

func loadSettings(p fyne.Preferences) app.Settings {
	s := app.DefaultSettings()
	s.Transport = app.TransportKind(p.StringWithFallback(prefTransport, string(s.Transport)))
	s.ScrollGain = p.FloatWithFallback(prefScrollGain, s.ScrollGain)
	s.ScrollInvert = p.BoolWithFallback(prefScrollInvert, s.ScrollInvert)
	return s
}

const (
	prefTransport    = "transport"
	prefScrollGain   = "scroll.gain"
	prefScrollInvert = "scroll.invert"
)
