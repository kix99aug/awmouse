// Package assets embeds the images the GUI needs at runtime.
package assets

import (
	_ "embed"

	"fyne.io/fyne/v2"
)

//go:embed icon-256.png
var iconPNG []byte

//go:embed tray.svg
var traySVG []byte

// Icon is the app icon, used for the window and the taskbar. The .app
// bundle's own icon comes from the 1024px original at package time.
var Icon = fyne.NewStaticResource("icon-256.png", iconPNG)

// Tray is the pointer glyph alone. It must be SVG: wrapping it in
// theme.NewThemedResource is what marks it as a template image on macOS, so
// the menu bar recolours it for light and dark appearance rather than showing
// a black smudge — and ThemedResource recolours by rewriting the XML, so a
// raster image comes back unchanged and logs an error on every redraw.
var Tray = fyne.NewStaticResource("tray.svg", traySVG)
