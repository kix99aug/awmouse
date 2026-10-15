import Combine
import Foundation
import WatchBridge

/// The phone's half of the watch link: takes what the watch sends and feeds it
/// into the same client the phone's own surfaces use, and tells the watch
/// whether there is a computer on the other end.
///
/// The watch can now dial the host itself, so this is no longer the only
/// route; it stays because it is the one that works on a watch too old for
/// the retargeted tunnel, and because the phone is the only side that can
/// scan a pairing code and so the only source of the address the watch needs.
@MainActor
final class WatchRelay: ObservableObject {
    @Published private(set) var watchReachable = false

    private let receiver = PhoneReceiver()
    private unowned let client: Client
    private var watching: Set<AnyCancellable> = []

    init(client: Client) {
        self.client = client

        receiver.onEvent = { [weak self] event in self?.apply(event) }
        receiver.$watchReachable.assign(to: &$watchReachable)
    }

    func activate() {
        // onAppear can fire more than once over a scene's life; a second
        // subscription would publish every change twice.
        guard watching.isEmpty else { return }
        receiver.activate()

        // The watch needs to know when the phone connects or drops, not only
        // when it happens to ask. Both the state and which computer it is
        // feed the one line the watch shows.
        client.$state
            .combineLatest(client.$attempting)
            .sink { [weak self] state, host in
                self?.publish(state: state, host: host)
            }
            .store(in: &watching)

        // Separate from the state above, and deliberately: application context
        // is latest-wins and replaces the whole dictionary, so a context sent
        // without the address erases the one the watch had stored. The phone
        // must therefore carry the address from the moment it launches, not
        // from the moment it next connects — otherwise opening the phone app
        // is what breaks the watch.
        client.$hosts
            .sink { [weak self] hosts in self?.publishCredentials(for: hosts.first) }
            .store(in: &watching)
    }

    /// Hands the watch what it needs to reach the computer by itself. The most
    /// recently used computer, because that is the one the watch should try —
    /// the same default the phone's own connect screen uses.
    private func publishCredentials(for host: KnownHost?) {
        guard let host else { return }
        receiver.publish(credentials: HostCredentials(
            address: host.address, key: ClientIdentity.key, name: host.name))
    }

    private func publish(state: Client.State, host: KnownHost?) {
        let connected = state == .connected
        receiver.publish(HostState(connected: connected, name: connected ? (host?.name ?? "") : ""))

        // A computer that has just answered outranks whatever was most
        // recently used, which may be a different one.
        if connected { publishCredentials(for: host) }
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
