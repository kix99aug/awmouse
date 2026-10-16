# awmouse — design

Use an Apple Watch (and iPhone) as a remote mouse for a Mac or Windows PC.
Drag on the glass → cursor moves. One finger taps a left click, two a right.

## Architecture

```
┌─ Apple Watch ─────────────┐
│  trackpad + crown         │
│  computer picker          │
└────────────┬──────────────┘
             │ WatchConnectivity — events up; status and computer list down
             ▼
┌─ iPhone app ──────────────┐
│  touch trackpad mode      │   ← also an input source, not just a relay
│  gyro air-mouse mode      │
│  QR scanner, host list    │
│  tailcat client           │
└────────────┬──────────────┘
             │ tailcat pipe — WireGuard encryption, NAT traversal, DERP fallback
             ▼
┌─ Host app (Go, Fyne) ─────┐
│  tray + pairing window    │
│  tailcat listener         │
│  accel curve + cursor pos │   ← owns feel, geometry, state
│  injector (absolute)      │
│    macOS  → CGEvent       │
│    Windows→ SendInput     │
└───────────────────────────┘
```

The phone relays the watch. The watch sends the same raw events the phone's
own trackpad produces; the phone tells the watch what it is doing about the
computer and which computers it knows, so the watch can show the state and
offer a choice.

### Why the watch goes through the phone

The watch reaching the host by itself was tried properly, and this records why
it was abandoned, so that it is not tried again on the same assumptions.

**The Go runtime does run on a watch.** Go has no watchOS port (no
`arm64_32` backend, golang/go#60180), but from Series 9 and Ultra 2 a watch is
plain arm64, so the iOS objects gomobile produces are correct code for it and
only their `LC_BUILD_VERSION` label says otherwise. Rewriting that label in
place (a fixed-size field; `vtool` cannot, because it rebuilds the load
commands and object files have no slack) links. The runtime then dies in
`initsig`, because watchOS traps inside libsystem's `sigaction` instead of
returning an error; redirecting that import to a no-op lets it start without
signal handlers. A key came back from `NewKey` on a Watch Ultra 3.

**The network does not.** watchOS denies low-level networking to third-party
apps (TN3135). On the watch, `NWPathMonitor` reads *unsatisfied* until the app
activates an audio session (`playAndRecord`, `spokenAudio`), and *satisfied*
within a fraction of a second after — so the documented exception does arrive.
But it arrives for Network framework only. At the same moment, to the same
DERP address, an `NWConnection` reached *ready* while a plain BSD socket's
`connect` failed with `EHOSTUNREACH` — from Swift as well as from Go, and with
Tailscale's interface pinning turned off. tailcat is BSD sockets throughout,
and Tailscale's region DERP client dials through `netns` with no hook to
substitute another dialer.

What would remain is a loopback proxy on the watch, so that Go connects to
127.0.0.1 and Swift carries the bytes out over `NWConnection`. That is DERP
only, since magicsock's UDP is sockets too — roughly 85 ms to the relay from
here, on each of two legs, for every cursor update. And it would stand on an
undocumented audio-session exception that Apple has acknowledged revokes itself
about 36 s after each activation (FB24377808), a microphone permission nothing
uses, and the `sigaction` patch. Any one of those changing in a watchOS release
breaks the watch outright. The relay's one real weakness — a phone app the user
swiped away — is handled instead by saying so, loudly, with Handoff.

An earlier round believed the direct route was working. It was not: the watch
showed the same green light for both routes, and the host could not tell them
apart because the watch was using the phone's identity. Every session that
worked had gone through the relay.

## Components

### Shared Swift package (`MotionInput`)

CoreMotion is identical on iOS and watchOS, so the sensor pipeline is written
once and linked into both targets:

- `MotionGeometry` — device-frame rotation → world-referenced yaw and pitch.
- `PointerFilter` — rotation rate → pointer delta. Pure math with no CoreMotion
  import, so the part that decides how an air mouse *feels* can be unit tested
  rather than only evaluated by waving a phone around.
- `MotionSource` — the CoreMotion wrapper that feeds both.

Used by the phone alone now. The watch reads no sensor, so it does not link
this at all.

**CoreMotion's handler must be explicitly `@Sendable`.** A closure formed
inside a `@MainActor` type and capturing `self` is inferred to be `@MainActor`
too, and CoreMotion's handler is neither Sendable nor isolated — so the
runtime checks isolation on entry and traps the moment it is called from
CoreMotion's own queue, before a line of the body runs. It passed on iOS only
while the handler happened to be invoked on the main queue; watchOS used
another. Marked `@Sendable` no check is inserted, and what must then be true
is that nothing unsendable crosses: `CMDeviceMotion` is a class, so each
sample is reduced to plain numbers on the delivery queue and only those go to
the main actor.

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

### Watch gesture set

The watch face is a trackpad and the crown is a scroll wheel — the phone's
gesture set, deliberately, so a hand does not have to learn two:

| Gesture | Action |
|---|---|
| drag with one finger | move the cursor |
| tap with one finger | left click |
| tap twice | double click |
| tap, then hold and drag | drag with the left button down |
| tap with two fingers | right click |
| tap twice with two fingers | middle click |
| turn the Digital Crown | scroll |

The whole screen is the pad; the status and a legend are drawn over it and take
no touches.

Finger counts come from `SpatialEventGesture` (watchOS 11). `DragGesture`
reports a single touch, which is why right click was once a timed hold — and
the hold fired whenever a finger rested before moving. `MagnifyGesture` and
`RotateGesture`, the other ways to notice a second finger, are unavailable on
watchOS.

Middle is a second two-finger tap rather than three fingers, because three
barely fit on a 46 mm screen. That makes the right click wait out the
double-tap window before it is sent: otherwise every middle click would open a
context menu first. The phone's strip makes the same trade for the same pair
of buttons. A left click never waits.

**There was a second mode that aimed by moving the wrist, and it was
removed.** Clicking meant knocking the watch; knocking the watch shook the arm
it was strapped to; and the gyro could not tell that jolt from aiming, so the
cursor slid away at the moment of every click. Freezing the cursor around each
knock — below the threshold that counted as a click, so the freeze began on
the leading edge — helped and did not fix it. The advantage it had, crossing a
display in one sweep, did not pay for a click that moved the thing it was
clicking on. The phone keeps its gyro mode, where the clicking hand is not the
aiming hand.

**Haptics stand in for the screen.** The cursor is on another display and the
watch is usually out of the line of sight, so a click that fired and a click
that was swallowed would be indistinguishable. Each one taps back.

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

The watch borrows all of it since `SpatialEventGesture` began reporting every
finger; see [Watch gesture set](#watch-gesture-set).

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

The watch has no gyro mode any more, and so no clutch; see
[Watch gesture set](#watch-gesture-set) for why aiming by wrist was removed.

### Host app

One Go codebase for macOS, Windows, and Linux. It is a Fyne application: a
tray icon, and one window with the pairing code, connection state, and
settings. There is no separate command-line daemon — a remote mouse for
people who are not going to open a terminal has to be something you
double-click.

Fyne needs cgo on every platform, which changes the build story: the
injector alone was pure Go on Windows and cross-compiled from anywhere, but
the GUI needs a C toolchain — mingw-w64 to cross-compile from a Mac, which
is what CI does. The wiring lives in `internal/app`, kept free of any UI
import, so the interface is a thin layer that renders a `Status` and pokes
a handful of setters.

The macOS build must be a `.app` bundle rather than a bare binary. The
Accessibility grant attaches to the application that owns the process, and
a bare executable double-clicked in Finder runs inside Terminal — so it is
Terminal that ends up in the permissions list, and the app appears never to
be granted anything. The bundle also sets `LSUIElement`: a menu-bar utility
has no business in the Dock.

```go
type Injector interface {
    MoveTo(x, y int32)          // ABSOLUTE, screen coordinates
    Button(b Button, down bool)
    Bounds() (w, h int32)
}
```

| Platform | API | cgo in the injector |
|---|---|---|
| macOS | `CGEventCreateMouseEvent` + `CGEventPost` | yes, ~40 lines |
| Windows | `SendInput`, `MOUSEEVENTF_ABSOLUTE\|MOVE\|VIRTUALDESK` | no (`x/sys/windows`) |
| Linux | `/dev/uinput` absolute device (`ABS_X`/`ABS_Y`) | no (`bendahl/uinput`) |

(The injectors are what is listed; the Fyne front end needs cgo everywhere
regardless.)

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
- **Windows** silently discards injected input aimed at a window owned by a
  more privileged process — User Interface Privilege Isolation. A medium
  integrity process (anything launched normally) cannot drive an elevated one,
  and the failure reports nothing at all: `SendInput` returns 1, sets no error,
  and the cursor does not move. Measured, not assumed: that is why
  `TestMoveMovesRealCursor` once failed with a game in the foreground.

  There is no way to detect it from the injection result, so the injector
  instead compares its own token's integrity level against the foreground
  window's and logs the explanation on transition. Comparing levels is exact;
  inferring it from "the cursor did not move" would be wrong whenever the user
  touches a physical mouse.

  Three ways out, in order of cost. Run elevated — the whole process then sits
  at high integrity and reaches elevated windows; a Task Scheduler entry with
  highest privileges avoids the UAC prompt on every launch. Or ship a manifest
  with `uiAccess="true"`, which is the route accessibility and remote-control
  software takes: it bypasses UIPI *without* admin, but demands an Authenticode
  signature from a trusted root and installation under a protected directory.
  Nothing reaches the secure desktop — the UAC prompt itself, the lock screen,
  Ctrl-Alt-Del — by design, at any privilege level.
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

**Motion is not applied as it arrives.** Each accelerated delta is added to a
pending amount and sets a deadline one estimated inter-arrival interval
away — an exponential estimate of how far apart deltas have been landing —
and a pump drains the pending amount linearly in 4 ms steps so that it is
all shown by that deadline. A delta that
arrives after a 100 ms gap therefore becomes ~25 small moves over the next
100 ms rather than one jump. This is what makes the cursor glide when the
network bunches messages up, which tailcat across the internet does; on a fast
link the interval is at or below the display's refresh period and the pump is
close to transparent.

Two details are not optional. The steps are 4 ms and not finer, because no
display samples the cursor faster than that and events posted between
refreshes are only ever posted, never seen. And the size of each step comes
from the time left to a deadline, not from a fixed slice count and not as
a fixed fraction of what is pending. Fixed slices assume the next arrival is
the same distance away, and when it is not, motion either piles up or has
to be skipped — the jump the pump exists to remove. A fixed fraction per
tick decays geometrically and never quite finishes, so every gesture ends
in a creeping sub-pixel tail (and a test waiting a fixed time for the whole
delta failed on a slow CI machine). Draining to a deadline is even, finishes
exactly on the tick that reaches it, and a new delta simply moves the
deadline out.

The cost is up to one interval of latency, with motion starting on the first
tick so the felt lag is a fraction of that. A click flushes whatever is still
pending before the button goes down, or the press would land short of where
the motion was heading by however much the pump had left to play.

## Pairing — QR on the computer

The host window shows a QR code and nothing else about the connection; the
phone scans it with its own camera. No address to paste, no code to type, no
IP entry, no firewall rules, no account — tailcat needs no Tailscale control
plane.

**Two credentials, doing different jobs.** The tailcat address says *where*
the host is, and never changes. The pairing code says *this phone may come
in*, and is spent the moment it does. Holding the address alone gets an
attacker a WireGuard session and a refusal.

- **Encode a deep link**, not a bare address: `awmouse://pair?tc=<address>&code=<code>`.
  The app's own scanner reads it, and so does the stock Camera app, which
  then launches the app. There is deliberately no way to type either half:
  the address is long and the code is short-lived, and a text field would
  put the secret on screen for no gain.
- **Hello first.** The phone's first message on every connection is a hello
  carrying whatever code it has. The host answers exactly once — `ok`, or
  `no` with a reason — and after `no` it closes the connection. This is the
  only message that ever flows host→phone; everything else stays one-way.
- **A phone that has been admitted once is admitted thereafter.** Its identity
  is its tailcat address, which is derived from its node key and bound to that
  key by WireGuard's cryptokey routing — a packet from that address came from
  the holder of that key, or it did not arrive. The **address**, with no port:
  the port is the connection's, freshly chosen each time, and keying a device
  on it means no phone is ever recognised twice. The host keeps the list beside
  its own identity, since the two mean nothing apart: rotating the host key
  changes the address every phone holds and un-pairs them all regardless.
- **Revocation is per phone.** Removing one from the list drops it at once if
  it is connected; no other phone notices. This is the property the address
  alone could never offer.
- **The code rotates on every admission and every sixty seconds**, and five
  wrong guesses in a row refuse all hellos for thirty seconds. A QR left on a
  shared screen or in a camera roll is therefore useless within a minute and
  useless immediately after anyone uses it; a guess at six digits through a
  redial per attempt is impractical without the lock and pointless with it.
  The window counts down under the QR so the change reads as design, not as
  a glitch.
- **The previous code stays good for fifteen seconds after a natural
  rotation.** A phone scans, then spends a few seconds bringing the tunnel
  up; landing on the wrong side of the minute in that gap must not send the
  user back to the screen. A code that was *spent* on an admission gets no
  such grace — the QR it came from may still be in view.
- **A paired phone reconnects on launch.** It remembers the address, and a
  known phone is admitted whatever code it sends, so opening the app
  reconnects to the last computer with no QR at all. The scan is for the
  first time, and for a new computer.
- **tailcat's own allow-list is not used**, though it exists. Once non-empty
  it refuses unknown keys at the WireGuard handshake, before any byte of ours
  runs — which is stronger, and also why it cannot work here: a new phone has
  to connect in order to present its code. The gate lives one layer up. The
  cost is that an address-holder can complete a handshake and reach the JSON
  reader; the reader answers `no` and hangs up.
- **One transport, tailcat, everywhere.** It finds a direct path on the same
  LAN as readily as across the internet, so the local-network WebSocket the
  pipeline was first built over was retired once the tunnel worked: keeping it
  would have meant a choice in the window that changed nothing the user could
  feel.
- **The watch pairs with nothing.** It reaches the host only through the
  phone, so it inherits whatever the phone is connected to. It can ask the
  phone to switch to another of its computers — the phone sends its list — but
  the choice is carried out by the phone.
- **A phone app the user swiped away cannot be reached, and no code fixes
  that.** iOS reads that gesture as "stop running this" and withholds every
  background launch, WatchConnectivity included, until the app is opened by
  hand. A phone app that is merely backgrounded or suspended is fine: the watch
  queues a transfer, and delivering it launches the app. When that has not
  brought the app back within a few seconds, the watch gives its whole screen
  to saying so, and advertises Handoff so the phone offers awmouse on its lock
  screen — one tap instead of going to find it.
- **The relay's live messaging can stall for good, and only a new phone
  process clears it.** Both apps log their session; twice, about three
  minutes after the phone app was launched in the background, the watch's
  messages stopped being answered while its queued transfers kept arriving and
  every session property on both sides still read healthy. Bringing the phone
  app to the front did not clear it; restarting the watch app did not; a new
  phone process did. So a wake request reaching a phone process that has been
  running a while is taken as that stall: in the background the app ends
  itself and the watch's next request launches a fresh one; in front it shows
  a banner asking to be reopened. The watch waits before its first request, so
  a phone app that merely has not answered yet is not restarted.
  Waking from a sleep is handled the same way, without waiting for the stall:
  the first message after a silence of more than ten seconds that reaches a
  phone process which sat through it in the background is not answered — the
  process ends — and the wake request the watch sends on waking launches a
  fresh one. The watch shows "reconnecting" until that one answers, so the
  light turns green once, and stays.
  Every message is answered with the phone's status, and the watch sends the
  next only after the answer — at a fixed 30 Hz without waiting, sends began
  failing outright with IDS errors.
- **The phone keeps a list of computers, not just the last one.** A person
  with a laptop and a desktop pairs with both and picks; the most recent is
  reconnected to without being asked, and the rest are one tap away when that
  one is off or out of reach. Each is stored as its address and the name the
  host gave — a list of base64 addresses would be unusable, so the host sends
  its name in the `ok` that answers a hello. Forgetting a computer on the
  phone only forgets the address; revoking the phone's access is the host's
  device list, and the two are independent on purpose.
- The watch has no camera and never pairs independently — it always inherits
  the phone's connection.

## Non-goal: standalone watch operation

**The paired iPhone, with the awmouse app running, is a hard requirement.** A
watch that reaches the host on its own was attempted and abandoned; see
[Why the watch goes through the phone](#why-the-watch-goes-through-the-phone).
A Swift client speaking tailcat's protocol over Network framework is the one
route left that does not stand on undocumented behaviour, and it means
implementing WireGuard and DERP by hand — security-critical work, and weeks of
it.

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
2. **iPhone touch-trackpad + host + tailcat pipe + QR pairing** — proves
   the whole path end to end using the easiest, most reliable input source.
3. **iPhone gyro air-mouse** — exercises the sensor pipeline without needing
   WatchConnectivity yet.
4. **watchOS app** — same shared package, relaying through a phone app that
   already works.

## Open questions / risks

Roughly in order of how likely they are to hurt:

0. **WatchConnectivity at pointer rates.** It is built for occasional small
   messages, not a stream, and no amount of reasoning settles what it will
   actually carry. Motion is therefore accumulated on the watch and flushed at
   30 Hz, and the watch counts what the link refuses and measures a round trip
   once a second — so the first wrist-test produces a number rather than an
   impression. If the drops are high, the rate comes down.
0. **watchOS suspends an app when the wrist drops.** Aiming would stop with
   it. Keeping a watch app alive means an extended runtime session, and the
   categories those come in — mindfulness, physical therapy — do not include
   "mouse"; claiming one to dodge the rule is the sort of thing review exists
   to catch. Whether this matters depends on how long the screen stays lit
   while an arm is actually aiming, which is a measurement, not an argument.

1. **Tap false positives.** Arm swing during normal movement resembles a tap
   spike. Needs tuning against recorded sensor traces; a fixed threshold picked
   by guessing will not hold up.
2. **Latency budget.** Three hops (watch → phone → host → OS). Each needs to
   stay lean or the cursor feels laggy. Measure early, on the real path.
3. **macOS Accessibility permission.** Real first-run UX friction.
4. **tailcat specifics** — mostly settled. The library (`github.com/tailscale/tailcat`,
   v0.6.0) exposes `Server` with an `OnTCP` accept hook and `Client.DialTCPPort`;
   the address is ~260 bytes of base64url, which is a comfortable QR. The
   host and phone halves pass a loopback-relay test, and the phone package
   cross-compiles for `ios/arm64` and `android/arm64` with cgo off. What is
   still unverified is `gomobile bind` itself and the Swift bridging, which
   need a Mac.
5. **Background execution** on iOS while the phone is pocketed and the watch is
   driving — may constrain how the relay stays alive.
6. **Windows `uiAccess` — deferred, not rejected.** Running elevated is the
   remedy the host offers today, via a notice at startup and a one-click
   restart. A manifest with `uiAccess="true"` would be better: it bypasses
   UIPI *without* admin rights, so elevated windows work while the host stays
   at medium integrity and never raises a UAC prompt. The prerequisites are
   what make it expensive, and all three are mandatory — Apple's Developer ID
   does nothing for them:
   - an Authenticode signature chaining to a root the machine already trusts,
     which for public distribution means buying a Windows code-signing
     certificate (OV, and since 2023 the key must live on an HSM or token);
   - installation under a protected directory — `Program Files` or
     `System32` — so a per-user or portable `.exe` is disqualified, meaning an
     installer rather than today's `awmouse-win.zip`;
   - `requestedExecutionLevel` left at `asInvoker` alongside it, since
     `uiAccess` and elevation are separate axes and asking for both is what
     makes the UAC prompt come back.

   Worth doing when awmouse is given to people who are not the author, since
   "approve a UAC prompt to use your mouse" is a bad first run. Not worth it
   while the audience is one machine. Either way it never reaches the secure
   desktop.
```
