import Combine
import Foundation
import WatchBridge
import WatchKit

/// The watch's whole behaviour: the face is a trackpad, the crown is a scroll
/// wheel, and everything goes to the computer by way of the phone app.
///
/// The watch cannot reach the computer itself. Go runs on a modern watch, but
/// watchOS refuses raw sockets to third-party apps — even the exception it
/// makes for audio apps covers Network framework only — and the tunnel is
/// built on raw sockets. DESIGN.md has the experiment that settled it.
///
/// There was once also a mode that aimed the cursor by moving the wrist. It is
/// gone because clicking meant knocking the watch, and the gyro could not tell
/// the knock from aiming, so the cursor slid away at the moment of every click.
@MainActor
final class WatchController: ObservableObject {
    /// False after a long sleep until the phone answers again; see
    /// `PhoneLink.confirmed`.
    @Published private(set) var confirmed = true

    /// Whether the phone app is answering right now — its heartbeat, not
    /// WatchConnectivity's `isReachable`, which on a watch only means the
    /// iPhone is nearby and stays true with the app suspended or gone.
    @Published private(set) var reachable = false

    /// The phone app has been unreachable for longer than it takes to wake
    /// it, so it is not coming without help: most likely the user swiped it
    /// out of the app switcher, which iOS will not undo for anyone.
    @Published private(set) var phoneMissing = false

    /// What the phone last reported about the computer.
    @Published private(set) var status: PhoneStatus?

    let link = PhoneLink()
    private var watching: Set<AnyCancellable> = []
    private var missingTimer: Task<Void, Never>?
    private var active = true

    /// How long the phone app may stay out of reach before the watch gives up
    /// on waking it and asks the user. Long enough to cover the phone
    /// recovering on its own — a stuck phone app ends itself on the first wake
    /// request and the next one launches it fresh, a few seconds in all — so
    /// that the notice means the app really is gone, not that it is restarting.
    private let patience: Duration = .seconds(5)

    /// How much scroll one detent of the crown is worth.
    ///
    /// The crown reports detents, and a detent meant one unit — which the
    /// host turns into about one and a half pixels. A notch of a real mouse
    /// wheel is nearer thirty, so a detent was worth a twentieth of what the
    /// hand expected. Calibrated here rather than through the host's scroll
    /// gain, because that gain is shared with the phone's two-finger scroll
    /// and this is a different instrument.
    private let crownScale = 20.0

    /// The watch's own multiplier on finger movement, applied before the
    /// host's acceleration curve.
    ///
    /// The host's curve is shared with the phone and tuned for it, and the
    /// watch face is about half as wide: the same curve made the watch feel
    /// slow, a display taking several swipes to cross. Scaling here leaves
    /// the phone alone. The interval is left as it was, so the host reads a
    /// faster finger and accelerates harder too — a fast flick gains more
    /// than a slow nudge, which is the point of scaling a small surface.
    @Published var speed: Double {
        didSet { UserDefaults.standard.set(speed, forKey: Self.speedKey) }
    }
    static let speedRange: ClosedRange<Double> = 1...4
    static let speedStep = 0.5
    private static let speedKey = "pointerSpeed"

    /// Onto the grid the settings offer, so a value stored under an older
    /// range or step still shows as one of the choices.
    static func snapped(_ value: Double) -> Double {
        let onGrid = (value / speedStep).rounded() * speedStep
        return min(max(onGrid, speedRange.lowerBound), speedRange.upperBound)
    }

    /// One step faster or slower, by -1 or +1.
    func stepSpeed(by steps: Int) {
        speed = Self.snapped(speed + Double(steps) * Self.speedStep)
    }

    init() {
        let stored = UserDefaults.standard.double(forKey: Self.speedKey)
        speed = stored == 0 ? 1 : Self.snapped(stored)
        link.$status.assign(to: &$status)
        link.$confirmed.assign(to: &$confirmed)
    }

    func activate() {
        guard watching.isEmpty else { return }
        link.$alive
            .removeDuplicates()
            .sink { [weak self] in self?.reachabilityChanged($0) }
            .store(in: &watching)
        link.activate()
    }

    /// Whether the watch app is in front and awake. Asleep, nothing it
    /// hears or fails to hear about the phone is evidence of anything, so no
    /// verdict is reached until it is awake again.
    func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        link.setActive(active)
        if active {
            if !reachable { startMissingTimer() }
        } else {
            missingTimer?.cancel()
            missingTimer = nil
        }
    }

    private func reachabilityChanged(_ now: Bool) {
        reachable = now
        missingTimer?.cancel()
        missingTimer = nil
        if now {
            phoneMissing = false
        } else if active {
            startMissingTimer()
        }
    }

    private func startMissingTimer() {
        missingTimer?.cancel()
        missingTimer = Task { [weak self] in
            guard let patience = self?.patience else { return }
            try? await Task.sleep(for: patience)
            guard let self, !Task.isCancelled, self.active, !self.reachable else { return }
            self.phoneMissing = true
        }
    }

    /// Asks the phone to switch to another of its computers.
    func choose(_ computer: KnownComputer) {
        link.pick(computer)
    }

    /// Whether anything the finger does will reach a cursor.
    var canReachCursor: Bool {
        reachable && confirmed && status?.phase == .connected
    }

    /// Finger movement on the watch face, in points. The same raw,
    /// unaccelerated delta the phone's trackpad sends: the host owns the
    /// curve, so a 40 mm screen and a 6" one need no different handling here.
    func trackpadMoved(dx: Double, dy: Double, dt: Double) {
        guard canReachCursor else { return }
        link.move(dx: dx * speed, dy: dy * speed, dt: dt)
    }

    /// Crown rotation. The crown is a scroll wheel that happens to be attached
    /// to a watch; using it for anything else would be perverse — and while
    /// the finger is moving the cursor it is the only thing free.
    func crownScrolled(by delta: Double) {
        guard delta != 0, canReachCursor else { return }
        link.scroll(dx: 0, dy: delta * crownScale)
    }

    /// Holds a button down or lets it go, for a selection drag.
    func press(_ button: WatchButton, down: Bool) {
        // A release always goes, even with the light not green: dropping it
        // would leave the computer holding the button down.
        guard canReachCursor || !down else { return }
        link.button(button, down: down)
        // Only the press is worth a tap on the wrist. Buzzing again on
        // release would fire at the end of every drag, when the user is
        // looking at the computer and has already felt the start.
        if down { WKInterfaceDevice.current().play(.start) }
    }

    /// No text on screen for a click — it covered the gesture legend — so
    /// the haptic is the whole confirmation, and there is none for a click
    /// that went nowhere.
    func click(_ button: WatchButton) {
        guard canReachCursor else { return }
        link.click(button)
        WKInterfaceDevice.current().play(button == .right ? .directionUp : .click)
    }
}
