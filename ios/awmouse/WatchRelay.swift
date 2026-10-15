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

    /// For the log: when the watch last checked in, and how much it sent.
    private var lastPing = Date.distantPast
    private var relayed = 0
    private var dropped = 0
    private var tally: Task<Void, Never>?

    init(client: Client) {
        self.client = client
        receiver.onEvent = { [weak self] in self?.apply($0) }
        receiver.onPick = { [weak self] in self?.pick($0) }
        // Woken by the watch with no window: someone is holding the watch
        // and wants the cursor.
        receiver.onWake = { [weak self] in
            RelayLog.note("woken by watch")
            self?.client.connectForRemoteUse()
        }
        receiver.onPing = { [weak self] in self?.pinged() }
    }

    func activate() {
        // Called on every launch; a second subscription would publish every
        // change twice.
        guard watching.isEmpty else { return }
        receiver.activate()

        client.$state
            .removeDuplicates()
            .sink { RelayLog.note("client \($0)") }
            .store(in: &watching)

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

    /// The watch checks in at least every two seconds while its app is open
    /// — with events while the cursor moves, with heartbeats otherwise. A longer
    /// gap means this app was not running to answer — suspended, most likely,
    /// and woken just now by this very message — and the tunnel may not have
    /// survived that.
    private func pinged() {
        let gap = Date().timeIntervalSince(lastPing)
        lastPing = Date()
        if gap > 6 && gap < .infinity {
            RelayLog.note(String(format: "watch ping after %.0fs gap; checking link", gap))
            client.verifyLink()
        }
    }

    /// The watch's computer picker. An explicit choice, like tapping the
    /// computer in the phone's own list.
    private func pick(_ id: String) {
        guard let host = client.hosts.first(where: { $0.address == id }) else { return }
        RelayLog.note("watch picked \(host.name)")
        client.connect(to: host)
    }

    private func apply(_ event: WatchEvent) {
        // The phone may have been woken by this very message with no tunnel
        // up. Connecting costs nothing when already connected — the attempt
        // sets state to connecting at once, so a stream of events produces one
        // dial, not thirty a second — and the event itself is dropped: there
        // is nowhere yet for a cursor movement to go.
        countEvent(relayed: client.state == .connected)
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

extension WatchRelay {
    /// Counts rather than lines: one per movement would bury everything else.
    /// Written out every few seconds while events are arriving.
    fileprivate func countEvent(relayed ok: Bool) {
        if ok { relayed += 1 } else { dropped += 1 }
        guard tally == nil else { return }
        tally = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            RelayLog.note("relayed \(self.relayed), dropped \(self.dropped) while not connected")
            self.relayed = 0
            self.dropped = 0
            self.tally = nil
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
