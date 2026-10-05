import Combine
import Foundation
import WatchBridge
import WatchKit

/// The watch's whole behaviour: the face is a trackpad, the crown is a scroll
/// wheel.
///
/// There was a second mode that aimed the cursor by moving the wrist. It is
/// gone, and the reason is worth keeping: clicking meant knocking the watch,
/// knocking the watch shook the arm it was strapped to, and the gyro could not
/// tell that from aiming — so the cursor slid away at the moment of every
/// click. Freezing the cursor around each knock helped and did not fix it. The
/// one advantage aiming had, crossing a display in a single sweep, did not pay
/// for that.
///
/// There are two ways out. The direct tunnel reaches the computer from the
/// watch itself and is preferred, because the phone cannot be relied on: iOS
/// will not relaunch an app the user swiped away, and that is the usual state
/// of the phone app when someone reaches for the watch. The phone relay is the
/// fallback, for a watch too old for the retargeted Go library and for the
/// first run, before the phone has handed over an address.
@MainActor
final class WatchController: ObservableObject {
    @Published private(set) var reachable = false
    @Published private(set) var host: HostState?

    /// The last thing that happened, for a line of feedback. The cursor is on
    /// another screen, so without this a click that did nothing and a click
    /// that worked look exactly alike.
    @Published private(set) var lastAction: String?

    /// Messages the link refused this session. WatchConnectivity at pointer
    /// rates is the part of this design that no amount of reasoning settles.
    @Published private(set) var dropped = 0

    let sender = WatchSender()
    let tunnel = DirectTunnel()

    /// How much scroll one detent of the crown is worth.
    ///
    /// The crown reports detents, and a detent meant one unit — which the
    /// host turns into about one and a half pixels. A notch of a real mouse
    /// wheel is nearer thirty, so a detent was worth a twentieth of what the
    /// hand expected. Calibrated here rather than through the host's scroll
    /// gain, because that gain is shared with the phone's two-finger scroll
    /// and this is a different instrument.
    private let crownScale = 20.0

    /// Whether the watch is driving the cursor itself rather than through the
    /// phone. Shown, because the two behave differently when the phone goes
    /// away and the user deserves to know which one they are on.
    @Published private(set) var direct = false

    init() {
        sender.$reachable.assign(to: &$reachable)
        sender.$host.assign(to: &$host)
        sender.$dropped.assign(to: &$dropped)
        tunnel.$state
            .map { $0 == .connected }
            .assign(to: &$direct)
    }

    func activate() {
        sender.activate()
        sender.resetStats()
        // Dial as soon as there is anything to dial with. The credentials
        // arrive from the phone, but the system keeps the last ones, so this
        // usually has them before the phone is even reachable.
        tunnel.connect(using: sender.credentials)
        sender.$credentials
            .compactMap { $0 }
            .sink { [weak self] credentials in self?.tunnel.connect(using: credentials) }
            .store(in: &watching)
    }

    private var watching: Set<AnyCancellable> = []

    /// Sends by whichever route is up, preferring the watch's own. Falling
    /// back rather than failing matters on the first run: the phone is right
    /// there, having just handed over the address, and the tunnel it describes
    /// has not finished dialling yet.
    private func emit(_ event: WatchEvent) {
        if tunnel.send(event) { return }
        switch event {
        case .move(let dx, let dy, let dt): sender.move(dx: dx, dy: dy, dt: dt)
        case .scroll(let dx, let dy): sender.scroll(dx: dx, dy: dy)
        case .click(let button): sender.click(button)
        }
    }

    /// Finger movement on the watch face, in points. The same raw,
    /// unaccelerated delta the phone's trackpad sends: the host owns the
    /// curve, so a 40 mm screen and a 6" one need no different handling here.
    func trackpadMoved(dx: Double, dy: Double, dt: Double) {
        guard canReachCursor else { return }
        emit(.move(dx: dx, dy: dy, dt: dt))
    }

    /// Crown rotation. The crown is a scroll wheel that happens to be attached
    /// to a watch; using it for anything else would be perverse — and while
    /// the finger is moving the cursor it is the only thing free.
    func crownScrolled(by delta: Double) {
        guard delta != 0, canReachCursor else { return }
        emit(.scroll(dx: 0, dy: delta * crownScale))
    }

    func click(_ button: WatchButton) {
        emit(.click(button))
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

    /// Whether there is a cursor at the far end to drive at all. The watch's
    /// own tunnel is enough on its own; the phone is only needed when there
    /// isn't one.
    var canReachCursor: Bool {
        direct || (reachable && host?.connected == true)
    }
}
