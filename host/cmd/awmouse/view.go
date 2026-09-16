package main

import (
	"context"
	"fmt"
	"image/color"
	"log"
	"net/url"
	"runtime"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/canvas"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/layout"
	"fyne.io/fyne/v2/widget"

	"awmouse/host/internal/app"
	"awmouse/host/internal/qr"
)

// view owns the widgets and knows how to paint a Status onto them. It never
// reads state on its own; follow() feeds it.
type view struct {
	root fyne.CanvasObject
	core *app.App

	dot    *canvas.Circle
	status *widget.Label
	code   *canvas.Image
	hint   *widget.Label

	// The QR is the only way in, and it changes every minute; the countdown
	// is what stops that looking like a glitch.
	countdown   *widget.Label
	codeExpires time.Time

	devices *fyne.Container
	devNote *widget.Label

	invert    *widget.Check
	gain      *widget.Slider
	gainValue *widget.Label

	permission fyne.CanvasObject
	failure    *widget.Label
	retry      *widget.Button

	// Set while render() writes to widgets, so their change callbacks know
	// the change came from us and not from the user.
	painting bool

	// The last endpoint rendered into the QR, so that status updates that
	// leave it unchanged do not re-encode and flicker the image.
	codeFor string
}

func newView(ctx context.Context, fa fyne.App, core *app.App) *view {
	v := &view{core: core}
	settings := core.Settings()

	// MARK: status line

	v.dot = canvas.NewCircle(color.Gray{Y: 0x99})
	dot := container.New(layout.NewGridWrapLayout(fyne.NewSize(10, 10)), v.dot)
	v.status = widget.NewLabel("Starting…")
	statusLine := container.NewHBox(container.NewCenter(dot), v.status)

	// MARK: pairing

	v.code = canvas.NewImageFromResource(nil)
	v.code.FillMode = canvas.ImageFillContain
	v.code.SetMinSize(fyne.NewSize(240, 240))

	v.hint = widget.NewLabel("Scan with awmouse on your phone. The code is good for a minute, then a new one appears.")
	v.hint.Wrapping = fyne.TextWrapWord
	v.hint.Alignment = fyne.TextAlignCenter
	v.hint.TextStyle = fyne.TextStyle{Italic: true}

	v.countdown = widget.NewLabel("")
	v.countdown.Alignment = fyne.TextAlignCenter
	v.countdown.TextStyle = fyne.TextStyle{Monospace: true}

	// MARK: paired devices

	v.devices = container.NewVBox()
	v.devNote = widget.NewLabel("Phones that have paired are let in without a code. Remove one to revoke it — it is dropped at once if connected.")
	v.devNote.Wrapping = fyne.TextWrapWord
	v.devNote.TextStyle = fyne.TextStyle{Italic: true}

	// MARK: scroll

	v.invert = widget.NewCheck("Invert scroll direction", func(on bool) {
		if v.painting {
			return
		}
		fa.Preferences().SetBool(prefScrollInvert, on)
		core.SetScroll(v.gain.Value, on)
	})

	v.gainValue = widget.NewLabel("")
	v.gain = widget.NewSlider(0.4, 4.0)
	v.gain.Step = 0.1
	v.gain.OnChanged = func(g float64) {
		v.gainValue.SetText(fmt.Sprintf("%.1f×", g))
		if v.painting {
			return
		}
		fa.Preferences().SetFloat(prefScrollGain, g)
		core.SetScroll(g, v.invert.Checked)
	}
	gainRow := container.NewBorder(nil, nil, widget.NewLabel("Scroll speed"), v.gainValue, v.gain)

	// MARK: permission (macOS) and failure

	v.permission = permissionCard(fa)
	v.permission.Hide()

	v.failure = widget.NewLabel("")
	v.failure.Wrapping = fyne.TextWrapWord
	v.failure.Importance = widget.DangerImportance
	v.failure.Hide()

	// The usual reason the tunnel fails to start is no network yet — a laptop
	// opened before Wi-Fi reconnected — and the remedy is to try again.
	v.retry = widget.NewButton("Try again", func() { go core.Restart(ctx) })
	v.retry.Hide()

	// MARK: assemble

	v.root = container.NewPadded(container.NewVBox(
		statusLine,
		v.permission,
		v.failure,
		container.NewCenter(v.retry),
		container.NewCenter(v.code),
		v.countdown,
		v.hint,
		widget.NewSeparator(),
		widget.NewLabelWithStyle("Paired phones", fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
		v.devices,
		v.devNote,
		widget.NewSeparator(),
		widget.NewLabelWithStyle("Scrolling", fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
		v.invert,
		gainRow,
	))

	// Initial values, from the saved settings.
	v.painting = true
	v.invert.SetChecked(settings.ScrollInvert)
	v.gain.SetValue(settings.ScrollGain)
	v.painting = false

	return v
}

// follow pushes every status change onto the UI thread. Fyne requires widget
// mutation to happen there, and the app reports from its own goroutines.
func (v *view) follow(core *app.App) {
	ch, stop := core.Subscribe()
	defer stop()
	for st := range ch {
		fyne.Do(func() { v.render(st) })
	}
}

// tick drives the countdown under the QR once a second, from the expiry the
// last status carried. Purely cosmetic; the app rotates the code on its own.
func (v *view) tick(ctx context.Context) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			fyne.Do(v.renderCountdown)
		}
	}
}

func (v *view) renderCountdown() {
	if v.codeExpires.IsZero() || !v.code.Visible() {
		v.countdown.SetText("")
		return
	}
	left := int(time.Until(v.codeExpires).Seconds())
	if left < 0 {
		left = 0
	}
	v.countdown.SetText(fmt.Sprintf("new code in %2ds", left))
}

func (v *view) render(st app.Status) {
	v.painting = true
	defer func() { v.painting = false }()

	var tint color.Color
	var text string
	switch st.Phase {
	case app.PhaseNeedsPermission:
		tint, text = color.RGBA{R: 0xE8, G: 0x9B, B: 0x1C, A: 0xFF}, "Waiting for permission"
	case app.PhaseStarting:
		tint, text = color.Gray{Y: 0x99}, "Finding the nearest relay…"
	case app.PhaseListening:
		tint, text = color.RGBA{R: 0x2E, G: 0xB8, B: 0x5C, A: 0xFF}, "Ready — waiting for the phone"
	case app.PhaseConnected:
		tint, text = color.RGBA{R: 0x3B, G: 0x7C, B: 0xF6, A: 0xFF}, "Connected"
	case app.PhaseFailed:
		tint, text = color.RGBA{R: 0xD6, G: 0x3C, B: 0x3C, A: 0xFF}, "Couldn't start"
	}
	v.dot.FillColor = tint
	v.dot.Refresh()
	v.status.SetText(text)

	if v.permission != nil {
		if st.Phase == app.PhaseNeedsPermission {
			v.permission.Show()
		} else {
			v.permission.Hide()
		}
	}

	if st.Phase == app.PhaseFailed {
		v.failure.SetText(st.Error)
		v.failure.Show()
		v.retry.Show()
	} else {
		v.failure.Hide()
		v.retry.Hide()
	}

	// The pairing code exists only while there is something to pair with.
	if st.Endpoint != "" {
		if st.Endpoint != v.codeFor {
			png, err := qr.PNG(st.Endpoint, 6)
			if err != nil {
				log.Printf("qr: %v", err)
			} else {
				v.code.Resource = fyne.NewStaticResource("pairing.png", png)
				v.code.Refresh()
				v.codeFor = st.Endpoint
			}
		}
		v.code.Show()
		v.hint.Show()
	} else {
		v.code.Hide()
		v.hint.Hide()
		v.codeFor = ""
	}

	v.codeExpires = st.CodeExpires
	v.renderCountdown()
	v.renderDevices(st)
}

func (v *view) renderDevices(st app.Status) {
	rows := make([]fyne.CanvasObject, 0, len(st.Devices))
	for _, d := range st.Devices {
		id := d.ID
		name := widget.NewLabel(d.Name)
		when := widget.NewLabel("since " + d.Since.Local().Format("Jan 2"))
		when.TextStyle = fyne.TextStyle{Italic: true}
		remove := widget.NewButton("Remove", func() {
			if err := v.core.Forget(id); err != nil {
				log.Printf("forget %s: %v", id, err)
			}
		})
		remove.Importance = widget.LowImportance
		rows = append(rows, container.NewBorder(nil, nil, name, container.NewHBox(when, remove)))
	}
	if len(rows) == 0 {
		empty := widget.NewLabel("None yet.")
		empty.TextStyle = fyne.TextStyle{Italic: true}
		rows = append(rows, empty)
	}
	v.devices.Objects = rows
	v.devices.Refresh()
}

// permissionCard explains the one thing macOS requires before the cursor
// will move, and opens the right pane. Nil on other platforms, where nothing
// is required.
func permissionCard(fa fyne.App) fyne.CanvasObject {
	if runtime.GOOS != "darwin" {
		return container.NewWithoutLayout()
	}

	body := widget.NewLabel("macOS needs to allow awmouse to control the cursor. " +
		"Turn on awmouse under Privacy & Security › Accessibility — this window will notice on its own. " +
		"If awmouse is already on there, that entry is an older copy: remove it and turn on this one.")
	body.Wrapping = fyne.TextWrapWord

	open := widget.NewButton("Open System Settings", func() {
		u, _ := url.Parse("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
		if err := fa.OpenURL(u); err != nil {
			log.Printf("open settings: %v", err)
		}
	})
	open.Importance = widget.HighImportance

	return widget.NewCard("Permission needed", "", container.NewVBox(body, open))
}
