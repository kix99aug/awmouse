// Package assets embeds the images the GUI needs at runtime.
package assets

import (
	_ "embed"

	"fyne.io/fyne/v2"
)

//go:embed icon-256.png
var iconPNG []byte

//go:embed tray.png
var trayPNG []byte

// Icon is the app icon, used for the window and the taskbar. The .app
// bundle's own icon comes from the 1024px original at package time.
var Icon = fyne.NewStaticResource("icon-256.png", iconPNG)

// Tray is the pointer glyph alone, black on transparent. Wrap it in
// theme.NewThemedResource before handing it to the system tray: that is what
// makes Fyne mark it as a template image on macOS, so the menu bar recolours
// it for light and dark appearance instead of showing a black smudge.
var Tray = fyne.NewStaticResource("tray.png", trayPNG)
