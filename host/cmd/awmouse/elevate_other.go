//go:build !windows

package main

import "fyne.io/fyne/v2"

// elevationNotice has nothing to say off Windows: UIPI is the only platform
// rule that lets a privileged window silently swallow injected input. macOS
// gates injection on an Accessibility grant instead, which permissionCard
// covers, and it reports being denied rather than pretending to work.
func elevationNotice(fyne.App, func()) fyne.CanvasObject { return nil }
