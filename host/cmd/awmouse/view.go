package main

import (
	"context"
	"fmt"
	"image/color"
	"log"
	"net/url"
	"runtime"

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

	dot     *canvas.Circle
	status  *widget.Label
	code    *canvas.Image
	address *widget.Label
	copy    *widget.Button
	hint    *widget.Label

	transport *widget.RadioGroup
	invert    *widget.Check
	gain      *widget.Slider
	gainValue *widget.Label

	permission fyne.CanvasObject
	failure    *widget.Label

	// Set while render() writes to widgets, so their change callbacks know
	// the change came from us and not from the user.
	painting bool

	// The last endpoint rendered into the QR, so that status updates that
	// leave it unchanged do not re-encode and flicker the image.
	codeFor string
}

const (
	labelLAN    = "Same Wi-Fi"
	labelTunnel = "Anywhere"
)

func newView(ctx context.Context, fa fyne.App, core *app.App) *view {
	v := &view{}
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

	v.address = widget.NewLabelWithStyle("", fyne.TextAlignCenter, fyne.TextStyle{Monospace: true})
	v.address.Wrapping = fyne.TextWrapBreak

	v.copy = widget.NewButton("Copy address", func() {
		fa.Clipboard().SetContent(v.address.Text)
	})
	v.copy.Importance = widget.LowImportance

	v.hint = widget.NewLabel("Scan with the phone's camera, or paste the address into the app.")
	v.hint.Wrapping = fyne.TextWrapWord
	v.hint.Alignment = fyne.TextAlignCenter
	v.hint.TextStyle = fyne.TextStyle{Italic: true}

	// MARK: transport

	v.transport = widget.NewRadioGroup([]string{labelLAN, labelTunnel}, func(sel string) {
		if v.painting {
			return
		}
		kind := app.TransportLAN
		if sel == labelTunnel {
			kind = app.TransportTunnel
		}
		fa.Preferences().SetString(prefTransport, string(kind))
		go core.SetTransport(ctx, kind)
	})
	v.transport.Horizontal = true
	v.transport.Required = true

	transportHelp := widget.NewLabel("Same Wi-Fi is direct. Anywhere works from any network through an encrypted tunnel; pairing takes a moment longer.")
	transportHelp.Wrapping = fyne.TextWrapWord
	transportHelp.TextStyle = fyne.TextStyle{Italic: true}

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

	// MARK: assemble

	v.root = container.NewPadded(container.NewVBox(
		statusLine,
		v.permission,
		v.failure,
		container.NewCenter(v.code),
		v.address,
		container.NewCenter(v.copy),
		v.hint,
		widget.NewSeparator(),
		widget.NewLabelWithStyle("Connect from", fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
		v.transport,
		transportHelp,
		widget.NewSeparator(),
		widget.NewLabelWithStyle("Scrolling", fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
		v.invert,
		gainRow,
	))

	// Initial values, from the saved settings.
	v.painting = true
	if settings.Transport == app.TransportTunnel {
		v.transport.SetSelected(labelTunnel)
	} else {
		v.transport.SetSelected(labelLAN)
	}
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

func (v *view) render(st app.Status) {
	v.painting = true
	defer func() { v.painting = false }()

	var tint color.Color
	var text string
	switch st.Phase {
	case app.PhaseNeedsPermission:
		tint, text = color.RGBA{R: 0xE8, G: 0x9B, B: 0x1C, A: 0xFF}, "Waiting for permission"
	case app.PhaseStarting:
		tint, text = color.Gray{Y: 0x99}, startingText(st.Transport)
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

	if st.Phase == app.PhaseFailed && st.Error != "" {
		v.failure.SetText(st.Error)
		v.failure.Show()
	} else {
		v.failure.Hide()
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
		v.address.SetText(st.Address)
		v.copy.Enable()
	} else {
		v.code.Hide()
		v.hint.Hide()
		v.codeFor = ""
		v.address.SetText("")
		v.copy.Disable()
	}

	if st.Transport == app.TransportTunnel {
		v.transport.SetSelected(labelTunnel)
	} else {
		v.transport.SetSelected(labelLAN)
	}
}

func startingText(kind app.TransportKind) string {
	if kind == app.TransportTunnel {
		return "Finding the nearest relay…"
	}
	return "Starting…"
}

// permissionCard explains the one thing macOS requires before the cursor
// will move, and opens the right pane. Nil on other platforms, where nothing
// is required.
func permissionCard(fa fyne.App) fyne.CanvasObject {
	if runtime.GOOS != "darwin" {
		return container.NewWithoutLayout()
	}

	body := widget.NewLabel("macOS needs to allow awmouse to control the cursor. " +
		"Turn it on under Privacy & Security › Accessibility — this window will notice on its own.")
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
