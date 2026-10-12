//go:build windows

package main

import (
	"errors"
	"fmt"
	"log"
	"os"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	"golang.org/x/sys/windows"

	"awmouse/host/internal/inject"
)

// prefHideElevationNotice remembers that the user has read the notice. The
// condition it describes never goes away, so without this the same card
// would greet them on every launch forever.
const prefHideElevationNotice = "windows.elevation.noticeHidden"

// elevationNotice is shown at startup when awmouse is not running elevated.
// Windows silently discards injected input aimed at a window owned by a more
// privileged process, so an app running as administrator in the foreground
// makes the cursor appear dead — see inject/uipi_windows.go.
//
// It appears up front rather than when the block is first detected, because by
// then the user is already mid-gesture, wondering whether the thing is broken.
// Most people never need elevation, so this is a notice with a button and not
// a prompt: staying unelevated is a perfectly good answer, and the default.
//
// Returns nil when there is nothing to say — already elevated, or dismissed.
func elevationNotice(fa fyne.App, quit func()) fyne.CanvasObject {
	if inject.Elevated() || fa.Preferences().Bool(prefHideElevationNotice) {
		return nil
	}

	body := widget.NewLabel("Windows will not let awmouse move the cursor while a window " +
		"that is running as administrator is in front — the cursor simply stops, " +
		"with no warning from Windows. Restart as administrator to reach those " +
		"windows too; Windows will ask you to confirm.")
	body.Wrapping = fyne.TextWrapWord

	restart := widget.NewButton("Restart as administrator", func() {
		if err := restartElevated(); err != nil {
			if errors.Is(err, windows.ERROR_CANCELLED) {
				log.Printf("elevation declined")
				return // the user said no; nothing is wrong
			}
			log.Printf("restart as administrator: %v", err)
			return
		}
		// The elevated copy is starting. Leave at once rather than let two
		// hosts fight over the same identity and relay.
		quit()
	})
	restart.Importance = widget.HighImportance

	// Ticking this records the preference but leaves the card up, so a stray
	// click stays undoable for as long as the window is open.
	hide := widget.NewCheck("Don't show this again at startup", func(on bool) {
		fa.Preferences().SetBool(prefHideElevationNotice, on)
	})

	return widget.NewCard("Administrator windows", "",
		container.NewVBox(body, restart, hide))
}

// restartElevated launches another copy of this executable with the "runas"
// verb, which is what raises the UAC prompt. The GUI takes no arguments, so
// there is nothing to forward.
func restartElevated() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	verb, err := windows.UTF16PtrFromString("runas")
	if err != nil {
		return err
	}
	file, err := windows.UTF16PtrFromString(exe)
	if err != nil {
		return err
	}
	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	dir, err := windows.UTF16PtrFromString(cwd)
	if err != nil {
		return err
	}
	if err := windows.ShellExecute(0, verb, file, nil, dir, windows.SW_SHOWNORMAL); err != nil {
		return fmt.Errorf("ShellExecute runas: %w", err)
	}
	return nil
}
