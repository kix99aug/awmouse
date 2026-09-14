# awmouse

Use a phone (and later an Apple Watch) as a remote mouse for a computer.

Design and rationale live in [DESIGN.md](DESIGN.md). This file is just how to
run the POC.

## Status

POC: iPhone touch-trackpad → macOS cursor, over a LAN WebSocket.

| Piece | State |
|---|---|
| macOS injection (`CGEvent`, absolute) | working |
| Acceleration curve + cursor state | working, untuned |
| iPhone touch trackpad | builds, needs on-device testing |
| LAN WebSocket transport | working |
| QR pairing | host renders it; in-app scanner not built (manual entry works) |
| tailcat transport | not started — deliberately after the input pipeline |
| Windows / Linux injection | not started |
| watchOS app | not started |

## Layout

```
host/                       Go daemon
  cmd/awmoused/             entry point, QR display
  internal/proto/           wire format
  internal/inject/          absolute cursor injection, per-OS
  internal/cursor/          acceleration curve + position state
  internal/transport/       Transport interface; WebSocket impl (tailcat swaps in here)
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
xcodegen generate
open AWMouse.xcodeproj
```

Run on a real device. The simulator's drag events come from a mouse, which
tells you nothing about how the trackpad actually feels — which is the only
question the POC exists to answer.

Enter the `ws://` address by hand, or scan the QR (it deep-links via
`awmouse://pair?ws=…`). Phone and computer must be on the same network; the LAN
restriction disappears once tailcat replaces this transport.

## Tests

```sh
cd host && go test ./...
```

`TestMoveMovesRealCursor` moves your actual cursor and puts it back — it is the
only honest way to check that cgo injection reaches the window server.
