//go:build windows

package main

import (
	"testing"

	"fyne.io/fyne/v2/test"

	"awmouse/host/internal/inject"
)

// TestElevationNoticeAppearsOnceDismissible covers the three states the card
// has. The notice is worth nothing if it either never shows or never stops.
func TestElevationNoticeAppearsOnceDismissible(t *testing.T) {
	fa := test.NewApp()
	t.Cleanup(func() { test.NewApp() })

	var quits int
	quit := func() { quits++ }

	card := elevationNotice(fa, quit)
	if inject.Elevated() {
		if card != nil {
			t.Error("an elevated host has nothing to warn about")
		}
		t.Skip("test run is elevated; the unelevated path needs a normal run")
	}
	if card == nil {
		t.Fatal("unelevated host showed no notice")
	}

	// Dismissing is the whole reason the preference exists: the condition
	// never clears, so the card has to be silenceable.
	fa.Preferences().SetBool(prefHideElevationNotice, true)
	if elevationNotice(fa, quit) != nil {
		t.Error("notice reappeared after being dismissed")
	}

	if quits != 0 {
		t.Errorf("quit called %d times without the button being pressed", quits)
	}
}
