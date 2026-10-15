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
    /// The last thing that happened, for a line of feedback. The cursor is on
    /// another screen, so without this a click that did nothing and a click
    /// that worked look exactly alike.
    @Published private(set) var lastAction: String?

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
    /// on waking it and asks the user. A background launch from the watch's
    /// wake request usually lands in a second or two.
    private let patience: Duration = .seconds(3)

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
    static let speedRange: ClosedRange<Double> = 0.5...4
    private static let speedKey = "pointerSpeed"

    init() {
        let stored = UserDefaults.standard.double(forKey: Self.speedKey)
        speed = stored == 0 ? 1 : min(max(stored, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        link.$status.assign(to: &$status)
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
        reachable && status?.phase == .connected
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
        guard canReachCursor else { return }
        link.button(button, down: down)
        // Only the press is worth a tap on the wrist. Buzzing again on
        // release would fire at the end of every drag, when the user is
        // looking at the computer and has already felt the start.
        if down {
            lastAction = "Drag"
            WKInterfaceDevice.current().play(.start)
        }
    }

    func click(_ button: WatchButton) {
        // No haptic for a click that went nowhere: the buzz is how the wrist
        // learns that a click happened.
        guard canReachCursor else { return }
        link.click(button)
        switch button {
        case .left:
            lastAction = "Left click"
            WKInterfaceDevice.current().play(.click)
        case .right:
            lastAction = "Right click"
            WKInterfaceDevice.current().play(.directionUp)
        case .middle:
            lastAction = "Middle click"
            WKInterfaceDevice.current().play(.click)
        }
    }
}
