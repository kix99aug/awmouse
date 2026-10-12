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
	"awmouse/host/internal/logs"
)

const appID = "space.keybo.awmouse.host"

func main() {
	logPath, logErr := logs.Setup()
	if logErr != nil {
		log.SetFlags(log.Ltime)
		log.Printf("logging to a file failed: %v", logErr)
	}
	log.Printf("awmouse starting (log: %s)", logPath)

	fa := fyneapp.NewWithID(appID)
	fa.SetIcon(assets.Icon)

	core, err := app.New(loadSettings(fa.Preferences()))
	if err != nil {
		log.Fatalf("app: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		if err := core.Run(ctx); err != nil && ctx.Err() == nil {
			log.Printf("app: %v", err)
		}
	}()

	w := fa.NewWindow("awmouse")
	v := newView(ctx, fa, core, fa.Quit)
	w.SetContent(v.root)
	w.Resize(fyne.NewSize(380, 640))

	// Deliberately not SetFixedSize(true). The window's content changes height
	// as it runs — the pairing code appears a second after launch, phones join
	// the list — and on a fixed-size window Fyne grows the OS window to the new
	// minimum without growing its own canvas with it. Everything is then drawn
	// in a space shorter than the window: a band of empty at the top, and every
	// click landing that far above where it looks like it should. Measured at
	// 200% scaling: the window went to 728pt while the canvas stayed at 692.

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
	go v.tick(ctx)

	w.ShowAndRun()
}

func loadSettings(p fyne.Preferences) app.Settings {
	s := app.DefaultSettings()
	s.ScrollGain = p.FloatWithFallback(prefScrollGain, s.ScrollGain)
	s.ScrollInvert = p.BoolWithFallback(prefScrollInvert, s.ScrollInvert)
	return s
}

const (
	prefScrollGain   = "scroll.gain"
	prefScrollInvert = "scroll.invert"
)
