# awmouse

Use a phone (and later an Apple Watch) as a remote mouse for a computer.

Design and rationale live in [DESIGN.md](DESIGN.md). This file is just how to
run the POC.

## Status

POC: iPhone touch-trackpad → macOS cursor, over a LAN WebSocket. Confirmed
working on device.

| Piece | State |
|---|---|
| macOS injection (`CGEvent`, absolute) | working |
| Acceleration curve + cursor state | working, untuned |
| iPhone trackpad, full gesture set | working |
| iPhone air mouse (gyro) | builds, needs on-device testing |
| Shared `MotionInput` package | working, unit tested |
| LAN WebSocket transport | working |
| QR pairing | host renders it; in-app scanner not built (manual entry works) |
| tailcat transport | not started — deliberately after the input pipeline |
| Windows / Linux injection | not started |
| watchOS app | not started |

## Gestures

| Gesture | Action |
|---|---|
| one finger drag | move cursor (Trackpad mode) |
| one finger held | engage the gyro (Air Mouse mode) |
| one finger tap | left click |
| two finger drag | scroll |
| two finger tap | right click |
| three finger tap | middle click |
| tap, then press and drag | drag with left button held |

Air Mouse aims by tilting the phone, and only while a finger rests on the
surface — a gyro with no clutch sends the cursor wandering every time you move
your arm. Everything except finger-translation keeps working in that mode, so
clicks, scroll, and drag are unchanged. Tune the slider rather than rebuilding;
it persists.

If scrolling feels inverted, run the host with `-scroll-invert`; `-scroll-gain`
adjusts its sensitivity. Pointer feel is `cursor.DefaultCurve` in
`host/internal/cursor/cursor.go`.

## Layout

```
host/                       Go daemon
  cmd/awmoused/             entry point, QR display
  internal/proto/           wire format
  internal/inject/          absolute cursor injection, per-OS
  internal/cursor/          acceleration curve + position state
  internal/transport/       Transport interface; WebSocket impl (tailcat swaps in here)
shared/MotionInput/         Swift package — gyro filtering, shared with watchOS later
ios/
  project.yml               XcodeGen source of truth — edit this, not the .xcodeproj
  AWMouse/                  SwiftUI client
```

## Running

**Host:**

```sh
cd host
go run ./cmd/awmoused
```

It prints a QR code and a `ws://` address.

macOS needs Accessibility permission, or `CGEventPost` silently does nothing.
The grant attaches to the app that owns the process, so when running from a
shell it is **your terminal** that must be enabled in System Settings › Privacy
& Security › Accessibility — not the `awmoused` binary.

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

Enter the `ws://` address by hand, or scan the QR (it deep-links via
`awmouse://pair?ws=…`). Phone and computer must be on the same network; the LAN
restriction disappears once tailcat replaces this transport.

## Tests

```sh
cd host && go test ./...
cd shared/MotionInput && swift test
```

`TestMoveMovesRealCursor` moves your actual cursor and puts it back — it is the
only honest way to check that cgo injection reaches the window server.

The `MotionInput` tests are pure math and need no device. The one that matters
most is `stillnessProducesNoDrift`: a cursor that wanders while the phone is
held still is the defining failure of an air mouse.
