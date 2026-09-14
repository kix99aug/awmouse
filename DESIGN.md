# awmouse — design

Use an Apple Watch (and iPhone) as a remote mouse for a Mac or Windows PC.
Move hand → cursor moves. Tap → left click. Double tap → right click.

## Architecture

```
┌─ Apple Watch ─────────────┐
│  gyro air-mouse           │
│  tap / double-tap detect  │
└────────────┬──────────────┘
             │ WatchConnectivity
             ▼
┌─ iPhone app ──────────────┐
│  touch trackpad mode      │   ← also an input source, not just a relay
│  gyro air-mouse mode      │
│  input arbiter            │   ← exactly one active source at a time
│  tailcat client           │
└────────────┬──────────────┘
             │ tailcat pipe — WireGuard encryption, NAT traversal, DERP fallback
             ▼
┌─ Host daemon (Go) ────────┐
│  tailcat listener         │
│  accel curve + cursor pos │   ← owns feel, geometry, state
│  injector (absolute)      │
│    macOS  → CGEvent       │
│    Windows→ SendInput     │
│    Linux  → uinput ABS    │
└───────────────────────────┘
```

The watch cannot speak tailcat directly, and the blocker is the Go compiler, not
gomobile's CLI surface: watchOS binaries must target `arm64_32` (64-bit hardware,
32-bit types), and Go has no `arm64_32` backend — golang/go#60180 is still open.
`gomobile bind -target` accordingly offers only ios / iossimulator / macos /
maccatalyst. There is no flag or workaround; the port does not exist.

The phone relay is therefore structural, not a convenience — which is what makes
it worth giving the phone its own input modes. See "Standalone watch mode" for
what it would take to lift this.

## Components

### Shared Swift package (`MotionInput`)

CoreMotion is identical on iOS and watchOS, so the sensor pipeline is written
once and linked into both targets:

- `MotionGeometry` — device-frame rotation → world-referenced yaw and pitch.
- `PointerFilter` — rotation rate → pointer delta. Pure math with no CoreMotion
  import, so the part that decides how an air mouse *feels* can be unit tested
  rather than only evaluated by waving a phone around.
- `MotionSource` — the CoreMotion wrapper that feeds both.
- tap detection (watch only, not yet built): peak detection on
  `CMDeviceMotion.userAcceleration` + ~300 ms debounce to disambiguate single
  from double.

Three decisions inside the filter, each of which is felt in the hand:

- **Scale by angle, not by rate.** Multiplying by `dt` makes the output points
  per radian turned, so the feel doesn't change when the sensor delivers samples
  at a different rate.
- **Subtractive deadzone, not a hard cut.** A hard threshold makes the cursor
  leap the instant it is crossed, because output jumps from zero straight to the
  full threshold value.
- **Smooth before gating.** Averaging the noise down first means the deadzone
  only has to reject what survives, rather than being wide enough to swallow raw
  jitter.

Use `CMDeviceMotion.rotationRate`, never `CMMotionManager.gyroData.rotationRate`
— the former is bias-corrected by CoreMotion's fusion, the latter is raw and its
bias walks the cursor across the screen while the device sits still.

**Resolve the aiming axes against gravity, never against a fixed device axis.**
Which axis means "aim sideways" depends on posture: held upright, turning left
rotates about the device's Y axis; lying flat, that same Y axis is horizontal
and rotating about it *rolls* the device instead. Assuming a fixed axis gets one
posture right and silently reads an unrelated gesture in the other — and with
whatever sign that unrelated gesture happens to carry, which is how this
surfaced: aiming worked upright, while flat the cursor answered to roll and
answered backwards. Projecting onto world vertical makes aiming mean one thing
at every angle.

An earlier draft of this document also put the wire protocol types here. That
was wrong: the watch talks to the phone over WatchConnectivity and never encodes
the JSON the host consumes, so sharing `Msg` would buy nothing.

Deliberately *not* using the watchOS system Double Tap gesture
(`.handGestureShortcut`): it requires Series 9 / Ultra 2 or newer, and it hands
you one fixed action rather than single-vs-double discrimination.

### iPhone gesture set

Finger count carries the meaning, matching a real trackpad:

**Everything common is reachable with one finger.** Holding the phone in one
hand makes two-finger gestures awkward, so multi-finger variants are kept as
conveniences rather than as the only route to anything.

| Gesture | Action |
|---|---|
| drag on main surface | move cursor (Air Mouse: hold and tilt) |
| tap main surface | left click |
| double tap | double click |
| double tap, then hold | press left and drag — selection |
| tap right strip | right click |
| double tap right strip | middle click |
| hold right strip | scroll — by sliding, or by tilting in Air Mouse |
| two finger drag | scroll (convenience) |
| two finger tap | right click (convenience) |
| three finger tap | middle click (convenience) |

Both surfaces run to their screen edge with no outer padding, and only their
inner corners are rounded. A rounded corner against the edge of the display is
just a gap that still accepts touches, and an edge target is the easiest thing
on a screen to hit without looking.

**The strip carries the double-tap delay that the main surface refuses.** Its
tap waits out the double-tap window before firing a right click, because a
second tap would make it a middle click instead. That is the same wait-and-see
latency rejected for left click — and it is fine here for the same reason it
was not there: right click is rare, left click is constant.

Right click lives on the strip rather than on a double tap, and the reason is
worth keeping: a double tap that meant right click would still have sent its
first tap's left click, because suppressing that would put a wait-and-see delay
back on **every** left click. Right click would arrive preceded by a stray left
click — harmless for a context menu, wrong on anything that acts immediately.
Putting it on its own target costs a strip of screen and nothing else, and it
leaves the double tap free to mean double click, which in turn makes
double-tap-and-hold mean selection exactly as a real trackpad does.

Whether the second press of a double tap becomes a selection or the second half
of a double click is decided **by time, not by movement**. A travel-based test
would work on the trackpad and never fire in Air Mouse mode, where the cursor is
driven by rotation and the finger does not move at all. The threshold is
`GestureTiming.tapMaxDuration` again, so the same hold length means the same
thing everywhere. Movement during the undecided press is withheld and flushed
only once it resolves into a drag, so a press that turns out to be a click never
nudges the cursor.

The host, not the phone, decides that two taps are a double click — see
[Click sequences](#click-sequences).

Both surfaces are built on UIKit touch handling. SwiftUI's `DragGesture` is a
single-touch abstraction that never reports how many fingers are down, so the
main surface is effectively a small trackpad driver. The strip needs no finger
count, but a `DragGesture` proved wrong there too: a tap that never moves may
produce no change callback at all, leaving gesture state to be inferred from
whatever the previous gesture left behind, which is how a tap ends up emitting
the wrong click. Raw touch events report press and release unconditionally.

Three details in the main surface are not optional:

- `isMultipleTouchEnabled` must be set, or every multi-finger gesture silently
  degrades to one finger.
- Motion is the centroid of the active touches, and the centroid **jumps**
  whenever a finger lands or lifts. Re-anchor on every change to the touch set,
  or each change is reported as a large spurious movement.
- Fingers rarely land on the same event, so move-vs-scroll is committed only
  after a few points of travel. Deciding at first touch would start a two-finger
  scroll as a cursor move. The same staggering means a tap's finger count must
  be the *peak* count seen during the touch, not the count at any one instant —
  and that a drag which acquires a second finger was never a drag.

The watch cannot borrow any of this: one wrist provides no finger count, so it
keeps single-vs-double tap discrimination and pays the ~300 ms delay that the
phone now avoids. See [Shared Swift package](#shared-swift-package-motioninput).

### Engage / clutch

Gyro picks up every incidental arm movement, so the cursor needs an explicit
live state. Without one it wanders whenever the device is merely carried. This
is the single easiest thing to skip and the most annoying to retrofit.

On the phone the clutch is **a finger resting on the surface**: rotation drives
the cursor only while something is touching. This costs nothing to build,
because the touch surface already exists, and it leaves the rest of the gesture
set intact — only finger *translation* is suspended in Air Mouse mode, so
scroll, taps, and drag keep working exactly as before. Re-engaging resets the
filter's smoothing state, so motion from before the clutch went down cannot
arrive as a jump on the first sample after it.

Engaging does not start motion immediately. The cursor is held still for
`GestureTiming.tapMaxDuration`; release inside that window and the gesture was a
tap, hold past it and the cursor comes alive. Otherwise tapping to click drags
the cursor off whatever it was aimed at during the press, which defeats the
point of aiming.

**That delay must be exactly the tap threshold, not merely close to it.** A
shorter delay opens a window in which the cursor has already started moving and
releasing *still* registers as a tap; a longer one makes holds that are too
short to aim also too long to click, so they do nothing at all. Sharing one
constant makes the two outcomes complementary by construction rather than by
coincidence. The moment motion begins, the filter is reset a second time — the
rotation made while deciding to hold would otherwise land as a jump.

The scroll strip waits too, for the same reason: it has a tap action of its own
now, so scrolling before the press has resolved would nudge the page on the way
to a right click. An earlier version skipped the pause there, correctly, back
when the strip did nothing but scroll.

The watch has no touch surface to spare and will need its own answer — holding
the Digital Crown is the obvious candidate.

### Host daemon

One Go codebase for macOS, Windows, and Linux. Only macOS needs cgo.

```go
type Injector interface {
    MoveTo(x, y int32)          // ABSOLUTE, screen coordinates
    Button(b Button, down bool)
    Bounds() (w, h int32)
}
```

| Platform | API | cgo |
|---|---|---|
| macOS | `CGEventCreateMouseEvent` + `CGEventPost` | yes, ~40 lines |
| Windows | `SendInput`, `MOUSEEVENTF_ABSOLUTE\|MOVE\|VIRTUALDESK` | no (`x/sys/windows`) |
| Linux | `/dev/uinput` absolute device (`ABS_X`/`ABS_Y`) | no (`bendahl/uinput`) |

Platform notes that will otherwise cost an afternoon each:

- **macOS** requires Accessibility permission to post events. Run from a
  terminal and the grant attaches to *the terminal app*, not to the binary —
  this confuses everyone at least once.
- **macOS** should also populate `kCGMouseEventDeltaX/Y` on the event, or apps
  that read deltas rather than position (games, 3D viewports) see nothing.
- **Windows** absolute coordinates are normalized to 0..65535, and
  `MOUSEEVENTF_VIRTUALDESK` is required for the span to cover all monitors
  rather than just the primary.
- **Windows** must declare DPI awareness (`SetProcessDpiAwarenessContext`,
  per-monitor V2) before touching geometry. A process that doesn't is handed
  virtualised, scaled coordinates on high-DPI displays: `GetSystemMetrics` and
  `GetCursorPos` disagree with where the cursor actually lands, and absolute
  positioning drifts by the scale factor.
- **Windows** `SendInput` compares `cbSize` against its own `sizeof(INPUT)` and
  injects *nothing* on a mismatch — no error, no event. The Go structs that
  mirror `INPUT`/`MOUSEINPUT` therefore carry a compile-time size assertion, so
  a layout slip fails the build instead of failing silently at runtime.
- **Windows** needs no click-count tracking and no drag-vs-move distinction:
  the OS derives double clicks from press timing itself, and a move while a
  button is held is already a drag.
- **Linux** `uinput` sits *below* the display server, so one code path covers
  X11, Wayland, and console with no compositor-specific work. The alternative,
  `libei` + XDG RemoteDesktop portal, is the "blessed" Wayland route but needs
  cgo, has immature Go bindings, and varies by desktop. The tradeoff is a trust
  model, not a capability one: `libei` prompts for consent, `uinput` does not.
- **Linux** needs write access to `/dev/uinput` — a udev rule granting a group,
  or root. Install-time step.

### Click sequences

macOS reads the click count from a field on the event rather than timing
presses itself, so two quick presses both carrying a count of 1 arrive as two
unrelated single clicks and **no application ever sees a double click**. The
injector therefore tracks consecutive presses and raises the count.

This belongs to the host, not the phone. The phone knows it sent two taps, but
whether they are close enough in time and space to form a sequence is a
platform judgement — and on Windows and Linux the OS makes it, so those
injectors will need nothing here.

A sequence continues only while the presses share a button, fall inside the
double-click interval, and stay within a few points of each other. The release
repeats whatever count its press carried, or an application would see a double
click begin and a single click end.

Only the left button accumulates. Double click has a defined meaning there and
nowhere else, and a right click arriving with a count of two makes some
applications reopen or flicker their context menu.

### Cursor model — absolute injection, host-side acceleration

Each OS applies its own pointer acceleration to relative motion (Linux via the
compositor, Windows via pointer accel and the "enhance pointer precision"
toggle), while macOS `CGEvent` is positional and bypasses acceleration entirely.
Feeding the same delta to all three therefore produces three different feels,
and macOS would need a hand-written curve regardless.

So the host owns the whole thing:

```
phone: finger drag → raw unaccelerated deltas (in points) ──wire──▶
host:  deltas → acceleration curve → accumulate virtual cursor position
                                   → clamp to screen bounds
                                   → inject ABSOLUTE position
```

Consequences:

- Every OS's native acceleration is bypassed. One curve, one feel, three
  platforms.
- The phone stays dumb: it never learns screen dimensions, DPI, or monitor
  layout, and the acceleration curve is never baked into the client. Retuning
  feel is a host-side change only.
- The host now holds cursor position as state, which can **desync from the real
  cursor** if the user also touches a physical mouse. Re-read the OS cursor
  position at gesture start where possible (`NSEvent.mouseLocation` /
  `GetCursorPos` / `XQueryPointer`). Wayland deliberately offers no way to query
  it, so there the drift is simply accepted — tolerable, since someone driving
  the cursor from a phone is rarely also using a mouse.
- Multi-monitor geometry becomes the host's problem on all three platforms.

Curve for the POC — keep it simple and tune later:
`gain = clamp(base + k·speed^p, min, max)`, with `speed = |delta| / dt`.

## Pairing — QR on the computer

The host prints a QR code; the phone scans it once. No IP entry, no firewall
rules, no account (tailcat needs no Tailscale control plane).

- **Render in the terminal** (`mdp/qrterminal`), not a GUI window — an ASCII QR
  survives SSH and headless hosts, and can still be drawn into a tray-app window
  later. A GUI-only QR cannot go the other direction.
- **Encode a deep link**, not a bare token: `awmouse://pair?t=<token>`. Scanning
  with the stock iOS Camera app then launches the app directly. In-app scanning
  via `AVCaptureMetadataOutput` is the fallback, not the primary path.
- **Scan once, not every launch.** The QR token is a short-lived bootstrap
  credential. On first successful handshake, each side persists the other's peer
  identity (iOS Keychain / host config file) and subsequent sessions reconnect
  silently. If the QR were required every time, the product would be unusable.
- **Expire the token** (~60 s, regenerate on demand). Whoever scans that QR gets
  mouse control of the machine, so it should not survive a screenshot or a
  shoulder-surf.
- The watch has no camera and never pairs independently — it always inherits the
  phone's connection.

## Non-goal: standalone watch operation

**The paired iPhone is a hard requirement.** A cellular watch with no phone
present is explicitly out of scope.

Recorded so this doesn't get re-litigated: the watch *could* network on its own
(`URLSession` and `Network.framework` both exist on watchOS), but it cannot run
tailcat, because of the `arm64_32` gap above. Replacing tailcat means replacing
what it was doing for free — NAT traversal — which means operating a relay, plus
CryptoKit end-to-end crypto so that relay stays untrusted. That trades away "no
account, no infrastructure," which is most of why tailcat was chosen. It is also
the slower path in practice: LTE plus a relay hop beats watch→phone Bluetooth
(~20–30 ms) only when the phone isn't on the host's LAN.

Consequence: the watch never pairs, never holds keys, and never speaks the wire
protocol to anything but the phone. Cuts real surface area from v1.

## Wire protocol

JSON. At 30 Hz this is ~1–2 KB/s, so the bandwidth argument for a packed binary
format doesn't apply, and being able to read the stream during debugging is
worth more.

```json
{"t":"m","dx":12,"dy":-4,"dt":33}  // relative, RAW (unaccelerated), dt in ms
{"t":"c","b":"l","d":true}         // button l|r|m, down/up
{"t":"s","dx":0,"dy":3}            // scroll, raw delta
```

Deltas on the wire stay **relative and unaccelerated** even though injection is
absolute — the phone is a trackpad-style surface (drag, lift, drag again to
continue), so relative is the only correct wire semantics. Absolute belongs at
the injection layer alone.

`dt` is carried explicitly rather than derived from arrival time: the
acceleration curve keys off speed, and network jitter would otherwise smear the
curve. When coalescing moves, sum `dt` along with `dx`/`dy`.

**Moves are lossy, clicks are reliable.** If the pipe backs up, pending move
deltas must be *coalesced by summing* into a single message rather than queued —
a backlog of stale deltas makes the cursor rubber-band. Clicks are discrete
events and must never be dropped or merged. Two different queue disciplines on
the same channel.

## Build order

Each stage validates the next:

1. **`MotionInput` shared package** — sensor math + protocol types, no I/O.
2. **iPhone touch-trackpad + host daemon + tailcat pipe + QR pairing** — proves
   the whole path end to end using the easiest, most reliable input source.
3. **iPhone gyro air-mouse** — exercises the sensor pipeline without needing
   WatchConnectivity yet.
4. **watchOS app** — same shared package, relaying through a phone app that
   already works.

## Open questions / risks

Roughly in order of how likely they are to hurt:

1. **Tap false positives.** Arm swing during normal movement resembles a tap
   spike. Needs tuning against recorded sensor traces; a fixed threshold picked
   by guessing will not hold up.
2. **Latency budget.** Three hops (watch → phone → host → OS). Each needs to
   stay lean or the cursor feels laggy. Measure early, on the real path.
3. **macOS Accessibility permission.** Real first-run UX friction.
4. **tailcat specifics to verify:** exact Go API surface, token format and byte
   size (QR capacity is ~2.9 KB alphanumeric, so almost certainly fine, but
   unconfirmed), and whether `gomobile bind` builds it cleanly for iOS.
5. **Background execution** on iOS while the phone is pocketed and the watch is
   driving — may constrain how the relay stays alive.
```
