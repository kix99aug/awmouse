# awmouse

Use a phone (and later an Apple Watch) as a remote mouse for a computer.

Design and rationale live in [DESIGN.md](DESIGN.md). This file is just how to
run the POC.

## Status

iPhone trackpad and air mouse → macOS or Windows cursor, over tailcat.
Confirmed working on device.

| Piece | State |
|---|---|
| macOS injection (`CGEvent`, absolute) | working |
| Acceleration curve + cursor state | working, untuned |
| iPhone trackpad, full gesture set | working |
| iPhone air mouse (gyro) | builds, needs on-device testing |
| Shared `MotionInput` package | working, unit tested |
| QR pairing | host renders it; in-app scanner not built (manual entry works) |
| tailcat transport | host side working, tested over a loopback relay; phone framework written, not yet bound or run on a device |
| Windows injection (`SendInput`, absolute) | working — cursor test passes on a 200% display; not yet driven from the phone |
| Linux injection (`uinput`) | not started |
| watchOS app | not started |

## Gestures

| Gesture | Action |
|---|---|
Everything common is reachable with one finger; the multi-finger gestures are
conveniences, since two fingers are awkward while one hand holds the phone.

| Gesture | Action |
|---|---|
| drag main surface | move cursor (Air Mouse: hold and tilt) |
| tap main surface | left click |
| double tap | double click |
| double tap, then hold | press left and drag — selection |
| tap right strip | right click |
| double tap right strip | middle click |
| hold right strip | scroll — by sliding, or by tilting in Air Mouse |
| two finger drag | scroll |
| two finger tap | right click |
| three finger tap | middle click |

Both surfaces reach their screen edge, so a thumb can find either without
aiming. The strip's right click waits out the double-tap window, since a second
tap means middle click instead — a delay that is fine on right click and would
not be on left.

Air Mouse aims by tilting the phone, and only while a finger rests on the
surface — a gyro with no clutch sends the cursor wandering every time you move
your arm. Everything except finger-translation keeps working in that mode, so
clicks, scroll, and drag are unchanged. Tune the slider rather than rebuilding;
it persists.

Holding down does not move the cursor straight away. It stays put for a quarter
second first: let go inside that pause and you get a click with the cursor
exactly where you aimed, keep holding and it starts tracking. The surface tint
tells you which of the two you are in. The scroll strip pauses the same way,
since tapping it is a right click.

Both sliders persist. Scroll wants a much gentler response than the pointer,
which is why they are separate.

If scrolling feels inverted, run the host with `-scroll-invert`; `-scroll-gain`
adjusts its sensitivity. Pointer feel is `cursor.DefaultCurve` in
`host/internal/cursor/cursor.go`.

## Layout

```
host/                       Go host app (Fyne)
  cmd/awmouse/              the tray app: pairing window, status, settings
  internal/app/             wires injector, cursor, transport; exposes status
  internal/proto/           wire format
  internal/inject/          absolute cursor injection, per-OS
  internal/cursor/          acceleration curve + position state
  internal/transport/       Transport interface; the tailcat impl
  mobile/awmtunnel/         the phone's end of the tailcat pipe, bound with gomobile
shared/MotionInput/         Swift package — gyro filtering, shared with watchOS later
ios/
  project.yml               XcodeGen source of truth — edit this, not the .xcodeproj
  icon.svg                  app icon source — `make icon` rasterises it into the asset catalog
  awmouse/                  SwiftUI client
```

## Running

**Host:**

```sh
cd host
make app        # macOS: dist/awmouse.app
make windows    # Windows: dist/awmouse.exe (needs `brew install mingw-w64` on a Mac)
make run        # just run it, unpackaged
```

It lives in the system tray. The window shows a QR code and the address to
pair with; closing the window hides it, and Quit is in the tray menu.

The connection is tailcat, and only tailcat: it works from any network, and
on the same one it finds a direct path at once, so a separate local-network
transport would add a choice without adding a capability. Starting takes a
second or two while the nearest relay is measured. Nothing needs opening in
a firewall: the relay is only used to find each other, and the traffic moves
to a direct path once one exists.

The QR carries a six-digit pairing code alongside the address. A phone the
host has not seen must present it; scanning supplies it, and there is no
other way in. The code changes after every pairing and every minute — the
window counts down — so an old screenshot of the QR gets nothing. Paired
phones are listed in the window; Remove revokes one on the spot.

The phone app reaches the tunnel through a Go framework that must be built
once on the Mac, before the Xcode project will resolve — gomobile is a module
tool of `host/go.mod`, so nothing to install beyond Go and Xcode:

```sh
cd ios && make tunnel
```

**macOS** needs Accessibility permission, or `CGEventPost` silently does
nothing. The app waits for it and says so; the button in the window opens
the right pane. This is why the host must be a `.app` bundle: the grant
attaches to the application that owns the process, and a bare binary
launched from Finder runs inside Terminal, so it would be Terminal that
ends up in the list. `make app` produces the bundle; it is unsigned, so the
first launch is right-click › Open.

**Windows** needs no permission. Fyne needs cgo, so building requires a C
compiler — MSYS2/mingw on Windows itself, or `brew install mingw-w64` to
cross-compile from a Mac. High-DPI is confirmed on a single 200% display:
the injector sees physical pixels, not the virtualised ones a DPI-unaware
process gets. Multi-monitor is not yet tried — if the cursor cannot reach a
second monitor, that is the `VIRTUALDESK` handling and worth reporting.

**iOS:**

```sh
cd ios
make open
```

`make` regenerates the project from `project.yml` and opens it. On a fresh
checkout it also seeds `Config/Local.xcconfig`; put your Apple team ID there to
build on a device. That file is gitignored and sits outside the `.xcodeproj`
precisely so regenerating cannot wipe it — otherwise Xcode appears to "forget"
the team on every generate. Find your team ID with:

```sh
security find-certificate -a -c "Apple Development" -p | openssl x509 -noout -subject
```

and take the `OU` field — not the code in the `CN` parentheses, which is the
certificate ID rather than the team.

Run on a real device. The simulator's drag events come from a mouse, which
tells you nothing about how the trackpad actually feels — which is the only
question the POC exists to answer.

Tap **Scan QR code** and point it at the computer. The stock Camera app
works too — the QR deep-links via `awmouse://pair?tc=…&code=…`. Once
paired, the app reconnects to the last computer on launch without a scan.

## CI

`codemagic.yaml` runs on every push to `main` and every PR, on macOS
runners, since both halves need Xcode: the macOS injector is cgo, and the
phone's tunnel is a gomobile framework.

| Workflow | What it proves | Output |
|---|---|---|
| `host` | `go vet`, `go test`, the phone package cross-compiles for iOS and Android | `awmouse.app` for macOS (zipped) and `awmouse.exe` for Windows |
| `ios` | the app compiles against the bound framework, unsigned; `MotionInput` tests | `.app` (not installable) |
| `ios-signed` | on a `v*` tag, or by hand — signs for App Store distribution and uploads to TestFlight | `.ipa`, and a TestFlight build |

`ios-signed` is the route onto a phone. It needs, once:

- An App Store Connect API key under Codemagic › Teams › Integrations, named
  `awmouse`, with the **Admin or App Manager** role — Developer cannot create
  the distribution certificate.
- The app record created in App Store Connect (bundle ID
  `space.keybo.awmouse`). `fetch-signing-files --create` registers the bundle
  ID in the developer portal, but the App Store Connect record is separate,
  and the upload fails without it.

Every run that finishes lands a build in TestFlight, available to anyone
with a role on the app; install it from the TestFlight app on the phone.

To release: set `MARKETING_VERSION` in `ios/project.yml` (and `VERSION` in
`host/Makefile` to match), commit, then

```sh
git tag v0.2 && git push --tags
```

The tag starts `ios-signed` on its own. Its first step refuses a tag that
disagrees with the project version, so a tag cannot ship the wrong number.
External testers need a `beta_groups` entry in `codemagic.yaml` and pass
through beta review once.

Build numbers come from Codemagic's `BUILD_NUMBER`, since TestFlight refuses
an upload it has seen before; locally the Makefile pins it to 1. Signing is
applied to the generated project by `xcode-project use-profiles`, so
`Local.xcconfig` stays empty on CI.

The app declares `ITSAppUsesNonExemptEncryption = false`: it uses WireGuard,
which is standard, published cryptography and therefore exempt from an
export licence. Without the key each TestFlight build waits at "Missing
Compliance" for the same answer to be given by hand.


```sh
cd host && go test ./...
cd shared/MotionInput && swift test
```

`TestMoveMovesRealCursor` moves your actual cursor and puts it back — it is the
only honest way to check that native injection reaches the window server. It
runs on macOS and Windows; on Linux there is no injector yet.

The tailcat tests (`internal/transport`, `mobile/awmtunnel`) run a real
WireGuard tunnel between the host transport and the phone package, through a
DERP relay started on loopback — no network access, and they finish in well
under a second.

The `MotionInput` tests are pure math and need no device. The one that matters
most is `stillnessProducesNoDrift`: a cursor that wanders while the phone is
held still is the defining failure of an air mouse.
