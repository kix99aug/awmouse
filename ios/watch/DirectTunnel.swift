import Foundation
import WatchBridge
#if canImport(Awmtunnel)
import Awmtunnel
#endif

/// The watch's connection to the computer — its only one. The phone is not
/// on the path: it hands over credentials once, and the cursor never travels
/// through it.
///
/// It could not be otherwise. iOS will not relaunch an app the user swiped out
/// of the switcher, so a watch that spoke through the phone was dead whenever
/// the phone app had been dismissed — which is most of the time, and exactly
/// when someone reaches for the watch.
///
/// The tunnel is the same Go library the phone uses, retargeted to watchOS by
/// ios/tools/watchify.py. Go has no watchOS port; what makes this work is that
/// a modern watch is arm64, so the compiled code is already correct and only
/// its platform label was wrong.
@MainActor
final class DirectTunnel: ObservableObject {
    enum State: Equatable {
        case idle          // nothing to dial with
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// One computer to dial, and the identity to dial it with.
    struct Target: Equatable, Sendable {
        var address: String
        var key: String
    }

    #if canImport(Awmtunnel)
    private var session: AwmtunnelSession?
    #endif
    private var dialing = false

    /// What to dial. Kept so a failed dial can be retried without being told
    /// again, and compared so that a change — another computer chosen —
    /// replaces the connection rather than being ignored.
    private var target: Target?
    private var retry: Task<Void, Never>?

    /// Backoff between attempts. A watch app is only ever in the foreground,
    /// so a tight retry would be a tight retry in someone's face; a slow one
    /// would leave them waiting after walking back into range.
    private let retryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15)]
    private var attempts = 0

    /// Events waiting to go, in order, and whether one is on the wire.
    ///
    /// One at a time, as the phone's client does it. Each send used to be its
    /// own detached task, and detached tasks keep no order — so a release
    /// could overtake the move before it, and a drag would let go of the
    /// selection one step short. Serialising also gives back-pressure for
    /// free: while one message is in flight, moves pile up here and merge into
    /// one instead of queueing behind each other.
    private var queue: [WatchEvent] = []
    private var sending = false

    /// Dials if there is something to dial and nothing in flight. Given a
    /// different target, drops the current connection and dials that instead.
    func connect(to new: Target?) {
        #if canImport(Awmtunnel)
        if let new, !new.address.isEmpty, new != target {
            target = new
            attempts = 0
            retry?.cancel()
            retry = nil
            if session != nil { close() }
        }
        guard let target else {
            state = .idle
            return
        }
        guard !dialing, session == nil else { return }
        retry?.cancel()
        retry = nil
        dialing = true
        state = .connecting

        Task { [weak self] in
            let outcome = await Self.dial(target)
            guard let self else { return }
            self.dialing = false
            // Another computer chosen while this dial was out: its result is
            // for a computer nobody wants any more.
            guard target == self.target else {
                if case .success(let stale) = outcome { Task.detached { _ = try? stale.close() } }
                self.connect(to: nil)
                return
            }
            switch outcome {
            case .success(let session):
                self.session = session
                self.attempts = 0
                self.state = .connected
            case .failure(let error):
                self.state = .failed(Self.describe(error))
                self.scheduleRetry()
            }
        }
        #else
        state = .idle
        #endif
    }

    /// Queues one event. Dropped when there is no tunnel: a cursor movement
    /// delivered after a reconnect would be a movement nobody made.
    func send(_ event: WatchEvent) {
        #if canImport(Awmtunnel)
        guard case .connected = state else { return }
        if let last = queue.last, let merged = last.merged(with: event) {
            queue[queue.count - 1] = merged
        } else {
            queue.append(event)
        }
        pump()
        #endif
    }

    #if canImport(Awmtunnel)
    private func pump() {
        guard !sending, !queue.isEmpty, let session else { return }
        let messages = queue.removeFirst().messages
        sending = true
        Task.detached { [weak self] in
            var failed = false
            do {
                for json in messages { try session.send(json) }
            } catch {
                failed = true
            }
            await self?.sent(failed: failed, on: session)
        }
    }

    private func sent(failed: Bool, on finished: AwmtunnelSession) {
        sending = false
        // A send that finished on a connection already replaced says nothing
        // about the current one.
        guard finished === session else { return pump() }
        if failed {
            lost()
        } else {
            pump()
        }
    }

    private func lost() {
        session = nil
        queue.removeAll()
        state = .failed("lost")
        scheduleRetry()
    }

    private func close() {
        let open = session
        session = nil
        queue.removeAll()
        Task.detached { _ = try? open?.close() }
    }

    /// Tries again on its own. Nothing else will: a watch app that has gone
    /// quiet is one the user is looking at, waiting for it to work.
    private func scheduleRetry() {
        guard retry == nil, target != nil else { return }
        let delay = retryDelays[min(attempts, retryDelays.count - 1)]
        attempts += 1
        retry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.retry = nil
            self.connect(to: nil)
        }
    }

    /// Off the main actor: dialling is a network round trip, and the watch's
    /// main thread is also drawing the trackpad the user is dragging on.
    private static func dial(_ target: Target) async -> Result<AwmtunnelSession, Error> {
        await Task.detached {
            do {
                // Dial is a top-level Go function, so gomobile exposes it as a
                // C function and the NSError** stays an out-parameter rather
                // than becoming `throws`.
                var error: NSError?
                let session = AwmtunnelDial(target.address, target.key, 15_000, nil, &error)
                if let error { return .failure(error) }
                guard let session else { return .failure(TunnelError.noSession) }

                // The host admits a device it already knows whatever code it
                // sends, and the watch never has one — it cannot scan. If the
                // host has forgotten this key, this is where it says so.
                let result = try session.hello("", name: deviceName, timeoutMillis: 5_000)
                guard result.admitted else {
                    _ = try? session.close()
                    return .failure(TunnelError.refused(result.reason))
                }
                return .success(session)
            } catch {
                return .failure(error)
            }
        }.value
    }

    /// A few words for the status line. These used to collapse into
    /// "offline", which made a computer that is off, a network that is down
    /// and a tunnel whose replies go somewhere else all look the same.
    private static func describe(_ error: Error) -> String {
        guard case TunnelError.refused(let reason) = error else {
            let text = (error as NSError).localizedDescription
            let lower = text.lowercased()
            // Nothing came back within the dial's 15 s. The computer is off
            // or asleep, awmouse is not running on it, or its replies are
            // going to another device holding the same identity.
            if lower.contains("deadline") || lower.contains("timeout") || lower.contains("timed out") {
                return "no answer"
            }
            if lower.contains("unreachable") || lower.contains("no such host") || lower.contains("dns") {
                return "no network"
            }
            // Anything else is unexpected, and the real text is the only
            // thing that will explain it.
            return String(text.prefix(40))
        }
        switch reason {
        // The host no longer knows this identity — forgotten in its device
        // list. Only a fresh pairing on the phone fixes that.
        case AwmtunnelReasonCode: return "not paired — pair on iPhone"
        case AwmtunnelReasonLocked: return "locked — try shortly"
        case "": return "refused"
        default: return reason
        }
    }
    #endif

    enum TunnelError: LocalizedError, Equatable {
        case noSession
        case refused(String)
    }
}

/// The watch reports itself by name so the host's device list can tell it from
/// the phone that paired it.
private let deviceName = "Apple Watch"
