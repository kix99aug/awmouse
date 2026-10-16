import Combine
import Foundation
import UIKit
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
final class WatchRelay: ObservableObject {
    /// The watch is not hearing this app, and the app is in front, where it
    /// will not end itself; see `wokenByWatch`. Shown as a banner asking for
    /// the restart that fixes it.
    @Published private(set) var stalled = false

    private let receiver = WatchReceiver()
    private unowned let client: Client
    private var watching: Set<AnyCancellable> = []

    /// For the log: when the watch last checked in, and how much it sent.
    private var lastPing = Date.distantPast
    private var relayed = 0
    private var dropped = 0
    private var heard = 0
    private var tally: Task<Void, Never>?

    init(client: Client) {
        self.client = client
        receiver.onEvent = { [weak self] in self?.apply($0) }
        receiver.onPick = { [weak self] in self?.pick($0) }
        // Woken by the watch with no window: someone is holding the watch
        // and wants the cursor.
        receiver.onWake = { [weak self] in self?.wokenByWatch(fresh: $0) }
        receiver.onPing = { [weak self] in self?.pinged() }
    }

    /// What WatchConnectivity believes right now, for the log.
    var sessionState: String { receiver.sessionState }

    func activate() {
        // Called on every launch; a second subscription would publish every
        // change twice.
        guard watching.isEmpty else { return }

        // The first message after the watch has slept is where a stale
        // background process ends itself instead of answering — decided on
        // WatchConnectivity's queue, so the delegate is told the app's state
        // as it changes rather than asking for it there.
        receiver.setInBackground(UIApplication.shared.applicationState == .background)
        for (name, background) in [
            (UIApplication.didEnterBackgroundNotification, true),
            (UIApplication.willEnterForegroundNotification, false),
        ] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in self?.receiver.setInBackground(background) }
                .store(in: &watching)
        }
        receiver.onStale { gap in
            RelayLog.note(String(format: "first watch message after %.0fs silence reached a stale background process; ending it so the watch's wake request launches a fresh one", gap))
            RelayLog.flush()
            exit(0)
        }

        receiver.activate()

        client.$state
            .removeDuplicates()
            .sink { RelayLog.note("client \($0)") }
            .store(in: &watching)

        client.$state
            .combineLatest(client.$attempting, client.$hosts, client.$verifying)
            .sink { [weak self] state, current, hosts, verifying in
                self?.publish(state: state, current: current, hosts: hosts, verifying: verifying)
            }
            .store(in: &watching)
    }

    private func publish(state: Client.State, current: KnownHost?, hosts: [KnownHost], verifying: Bool) {
        let phase: PhoneStatus.Phase
        var note: String?
        switch state {
        case .connected where verifying:
            // Woken from suspension and checking the tunnel survived. Not
            // green yet: input sent now may go nowhere.
            phase = .connecting
            note = "reconnecting"
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
        stalled = false
        heard += 1
        startTally()
        if gap > 6 && gap < .infinity {
            // The same threshold the delegate used when it answered this
            // message "reconnecting".
            RelayLog.note(String(format: "watch ping after %.0fs gap; checking link", gap))
            client.verifyLink()
        }
    }

    /// The watch asked this app to be running.
    ///
    /// The watch sends that only after its messages have gone unanswered for
    /// a few seconds. Arriving at a process that has just been launched, it is
    /// the launch doing its job. Arriving at one that has been running a while,
    /// it means the watch is not hearing this process — and the logs showed
    /// what that is: about three minutes into running in the background, iOS
    /// suspends the app, and WatchConnectivity's live messaging to that
    /// process stops for good, in both directions, while queued transfers like
    /// this one keep arriving and every session property still reads healthy.
    /// It survived the app being brought to the front. Only a new process
    /// recovered it.
    ///
    /// So a process in that state ends itself, and the watch's next wake
    /// request launches a fresh one in the background, which works. Only in
    /// the background, where nobody is looking at the app; in front, it asks.
    /// An app ending itself is not something App Review likes, and this is
    /// the one place it happens.
    ///
    /// `fresh` is the watch waking from a long sleep. A background process
    /// that sat through it is ended just the same — it is the kind that
    /// stalls — but in front nothing is wrong, so there is no banner.
    private func wokenByWatch(fresh: Bool) {
        let age = Date().timeIntervalSince(AppCore.shared.launchedAt)
        let background = UIApplication.shared.applicationState == .background
        guard age > 10, background || !fresh else {
            RelayLog.note(fresh ? "woken by watch after its sleep" : "woken by watch")
            client.connectForRemoteUse()
            return
        }
        let quiet = Date().timeIntervalSince(lastPing)
        RelayLog.note(String(format: "wake request %.0fs into this process, %.1fs since last message: watch is not hearing us", age, quiet))
        if background {
            RelayLog.note("ending this process so the watch can launch a fresh one")
            RelayLog.flush()
            exit(0)
        }
        stalled = true
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
        startTally()
    }

    /// Every message counts, heartbeats included: with only events counted,
    /// a watch that was idle and a watch that could not get through looked
    /// the same.
    fileprivate func startTally() {
        guard tally == nil else { return }
        tally = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            RelayLog.note("heard \(self.heard) messages; relayed \(self.relayed), dropped \(self.dropped) while not connected")
            self.heard = 0
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
