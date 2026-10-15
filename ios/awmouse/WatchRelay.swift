import Combine
import Foundation
import WatchBridge

/// The phone's half of the watch link: takes what the watch sends and feeds it
/// into the same client the phone's own surfaces use, and tells the watch what
/// the phone is doing about the computer.
///
/// The watch cannot reach the computer itself. watchOS keeps raw sockets from
/// third-party apps — even the exception it grants to audio apps covers only
/// Network framework — and tailcat is made of raw sockets. That was found out
/// the hard way; see DESIGN.md. So everything the watch does arrives here
/// first, and this is the narrowest useful place to relay it: the watch
/// produces exactly the events the phone's trackpad produces, so there is
/// nothing to translate.
@MainActor
final class WatchRelay {
    private let receiver = WatchReceiver()
    private unowned let client: Client
    private var watching: Set<AnyCancellable> = []

    init(client: Client) {
        self.client = client
        receiver.onEvent = { [weak self] in self?.apply($0) }
        receiver.onPick = { [weak self] in self?.pick($0) }
        // Woken by the watch with no window: someone is holding the watch
        // and wants the cursor.
        receiver.onWake = { [weak self] in self?.client.connectForRemoteUse() }
    }

    func activate() {
        // Called on every launch; a second subscription would publish every
        // change twice.
        guard watching.isEmpty else { return }
        receiver.activate()

        client.$state
            .combineLatest(client.$attempting, client.$hosts)
            .sink { [weak self] state, current, hosts in
                self?.publish(state: state, current: current, hosts: hosts)
            }
            .store(in: &watching)
    }

    private func publish(state: Client.State, current: KnownHost?, hosts: [KnownHost]) {
        let phase: PhoneStatus.Phase
        var note: String?
        switch state {
        case .connected: phase = .connected
        case .connecting: phase = .connecting
        case .disconnected: phase = .idle
        case .needsRescan:
            phase = .idle
            note = "scan the code on iPhone"
        case .failed(let message):
            phase = .idle
            note = message
        }
        receiver.publish(PhoneStatus(
            phase: phase,
            current: current.map(Self.computer),
            computers: hosts.map(Self.computer),
            note: note))
    }

    private static func computer(_ host: KnownHost) -> KnownComputer {
        KnownComputer(id: host.address, name: host.name)
    }

    /// The watch's computer picker. An explicit choice, like tapping the
    /// computer in the phone's own list.
    private func pick(_ id: String) {
        guard let host = client.hosts.first(where: { $0.address == id }) else { return }
        client.connect(to: host)
    }

    private func apply(_ event: WatchEvent) {
        // The phone may have been woken by this very message with no tunnel
        // up. Connecting costs nothing when already connected — the attempt
        // sets state to connecting at once, so a stream of events produces one
        // dial, not thirty a second — and the event itself is dropped: there
        // is nowhere yet for a cursor movement to go.
        guard client.state == .connected else {
            client.connectForRemoteUse()
            return
        }

        switch event {
        case .move(let dx, let dy, let dt):
            client.move(dx: dx, dy: dy, dt: dt)
        case .scroll(let dx, let dy):
            client.scroll(dx: dx, dy: dy)
        case .click(let button):
            client.click(button.asMouseButton)
        case .button(let button, let down):
            client.button(button.asMouseButton, down: down)
        }
    }
}

private extension WatchButton {
    /// The two enumerations are deliberately separate: one is the watch link's
    /// vocabulary and one is the host protocol's, and tying them together
    /// would make a change to either a change to both.
    var asMouseButton: MouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .middle
        }
    }
}
