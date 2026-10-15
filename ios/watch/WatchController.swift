import Combine
import Foundation
import WatchBridge
import WatchKit

/// The watch's whole behaviour: the face is a trackpad, the crown is a scroll
/// wheel, and everything goes to the computer over the watch's own tunnel.
///
/// The phone has one job here, and only until it has done it: handing over
/// the address and identity, which the watch cannot get any other way because
/// it cannot scan a pairing code. It is never on the path the cursor takes. It
/// used to be — events went to the phone app and the phone forwarded them —
/// and that is gone for two reasons. iOS will not relaunch an app the user
/// swiped away, so the relay was down exactly when it was wanted; and a phone
/// woken to relay would dial the computer with the same identity the watch was
/// already using, and the two connections fought.
///
/// There was also once a mode that aimed the cursor by moving the wrist. It is
/// gone because clicking meant knocking the watch, and the gyro could not tell
/// the knock from aiming, so the cursor slid away at the moment of every click.
@MainActor
final class WatchController: ObservableObject {
    /// The last thing that happened, for a line of feedback. The cursor is on
    /// another screen, so without this a click that did nothing and a click
    /// that worked look exactly alike.
    @Published private(set) var lastAction: String?

    /// Whether the tunnel is up, which is the same as whether anything the
    /// finger does will reach the cursor.
    @Published private(set) var connected = false

    /// What the tunnel is doing while it is not carrying anything: dialling,
    /// or why it stopped.
    @Published private(set) var linkNote: String?

    /// Where getting credentials from the phone stands.
    @Published private(set) var credentialPhase: CredentialSource.Phase = .asking

    /// What the computer calls itself, for the status line.
    @Published private(set) var hostName: String?

    let credentials = CredentialSource()
    private let tunnel = DirectTunnel()
    private var watching: Set<AnyCancellable> = []

    /// How much scroll one detent of the crown is worth.
    ///
    /// The crown reports detents, and a detent meant one unit — which the
    /// host turns into about one and a half pixels. A notch of a real mouse
    /// wheel is nearer thirty, so a detent was worth a twentieth of what the
    /// hand expected. Calibrated here rather than through the host's scroll
    /// gain, because that gain is shared with the phone's two-finger scroll
    /// and this is a different instrument.
    private let crownScale = 20.0

    init() {
        // Mirrored rather than read through the owned objects: a nested
        // ObservableObject does not republish the view that observes its
        // owner, so a view reading tunnel.state directly would never redraw.
        tunnel.$state
            .map { $0 == .connected }
            .assign(to: &$connected)
        tunnel.$state
            .map { state -> String? in
                switch state {
                case .connecting: return "connecting"
                case .failed(let why): return why
                case .idle, .connected: return nil
                }
            }
            .assign(to: &$linkNote)
        credentials.$phase.assign(to: &$credentialPhase)
        credentials.$credentials
            .map { $0?.name }
            .assign(to: &$hostName)
    }

    func activate() {
        guard watching.isEmpty else { return }
        // Stored credentials are loaded synchronously, so a watch that has
        // them dials here, before the phone has been consulted about
        // anything. Later values are the phone switching computers.
        credentials.$credentials
            .compactMap { $0 }
            .sink { [weak self] in self?.tunnel.connect(using: $0) }
            .store(in: &watching)
        credentials.activate()
    }

    /// Asks the phone again — for when the user has just opened it.
    func retryCredentials() {
        credentials.requestIfNeeded()
    }

    /// Finger movement on the watch face, in points. The same raw,
    /// unaccelerated delta the phone's trackpad sends: the host owns the
    /// curve, so a 40 mm screen and a 6" one need no different handling here.
    func trackpadMoved(dx: Double, dy: Double, dt: Double) {
        tunnel.send(.move(dx: dx, dy: dy, dt: dt))
    }

    /// Crown rotation. The crown is a scroll wheel that happens to be attached
    /// to a watch; using it for anything else would be perverse — and while
    /// the finger is moving the cursor it is the only thing free.
    func crownScrolled(by delta: Double) {
        guard delta != 0 else { return }
        tunnel.send(.scroll(dx: 0, dy: delta * crownScale))
    }

    /// Holds a button down or lets it go, for a selection drag.
    func press(_ button: WatchButton, down: Bool) {
        guard connected else { return }
        tunnel.send(.button(button, down: down))
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
        guard connected else { return }
        tunnel.send(.click(button))
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
