#if canImport(WatchConnectivity)

import Foundation
import WatchConnectivity

/// Marks the transfer whose only purpose is to get the phone app running.
let wakeKey = "wake"
/// Marks the message asking the phone to switch to another computer.
let pickKey = "pick"

/// Forwards WCSession's callbacks, which arrive on a background queue, to
/// closures that hop to the main actor. Kept apart from the types that use it
/// so that neither of them has to pretend the delegate is main-actor.
final class SessionDelegate: NSObject, WCSessionDelegate, @unchecked Sendable {
    var onEvent: (@MainActor (WatchEvent) -> Void)?
    var onPick: (@MainActor (String) -> Void)?
    var onStatus: (@MainActor (PhoneStatus) -> Void)?
    var onReachability: (@MainActor (Bool) -> Void)?
    var onActivated: (@MainActor () -> Void)?
    var onWake: (@MainActor () -> Void)?

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {
        if let error { print("watch session: \(error)") }
        let reachable = session.isReachable
        let activated = state == .activated
        Task { @MainActor in
            self.onReachability?(reachable)
            if activated { self.onActivated?() }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.onReachability?(reachable) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let address = message[pickKey] as? String {
            Task { @MainActor in self.onPick?(address) }
            return
        }
        guard let event = WatchEvent(payload: message) else { return }
        Task { @MainActor in self.onEvent?(event) }
    }

    /// The watch asking the phone app to be running. Queued transfers are
    /// delivered by launching the app if it is not running, which plain
    /// messages cannot do — they need the app to be reachable already, and it
    /// is not reachable precisely when it is not running.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard userInfo[wakeKey] != nil else { return }
        Task { @MainActor in self.onWake?() }
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        guard let status = PhoneStatus(payload: context) else { return }
        Task { @MainActor in self.onStatus?(status) }
    }

    #if os(iOS)
    // Required on iOS, where one watch can be swapped for another.
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}

// MARK: - Watch side

/// The watch's end: sends events to the phone app, and knows whether it is
/// there and what it is doing.
@MainActor
public final class PhoneLink: ObservableObject {
    /// Whether the phone app is running and answering. `sendMessage` only
    /// works while it is, which is right for a mouse: a cursor movement
    /// delivered later is worse than none.
    @Published public private(set) var reachable = false

    /// What the phone last said, or nil if it has said nothing yet. A phone
    /// that has never reported and a phone reporting no computer look alike
    /// on the wrist, and are completely different faults.
    @Published public private(set) var status: PhoneStatus?

    private let delegate = SessionDelegate()
    private var pump: Task<Void, Never>?
    private var lastWake = Date.distantPast

    /// Pending motion, summed. Deltas are far too frequent to send one
    /// message each — WatchConnectivity is not a 60 Hz pipe — so they are
    /// accumulated and flushed at a fixed rate. Summing is lossless for
    /// position: ten small moves and their total land the cursor in the same
    /// place.
    private var moveDX = 0.0, moveDY = 0.0, moveDT = 0.0
    private var scrollDX = 0.0, scrollDY = 0.0

    /// How often queued motion is flushed. 30 Hz is about what
    /// WatchConnectivity will carry.
    public var interval: Duration = .milliseconds(33)

    public init() {}

    public func activate() {
        guard WCSession.isSupported(), pump == nil else { return }
        delegate.onReachability = { [weak self] in self?.reachable = $0 }
        delegate.onStatus = { [weak self] in self?.status = $0 }
        // The status the phone sent while this app was not running waits in
        // the session, but only once the session is up: activation is
        // asynchronous, and reading it on the line after activate() reads
        // nothing.
        delegate.onActivated = { [weak self] in self?.loadStoredStatus() }

        let session = WCSession.default
        session.delegate = delegate
        session.activate()
        loadStoredStatus()

        pump = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.interval ?? .milliseconds(33))
                guard let self else { return }
                self.flush()
                // While this app is open and the phone app is not there, keep
                // asking it to be. wakePhone rate-limits itself, and stops
                // mattering the moment the phone answers.
                if !self.reachable { self.wakePhone() }
            }
        }
    }

    private func loadStoredStatus() {
        if let stored = PhoneStatus(payload: WCSession.default.receivedApplicationContext) {
            status = stored
        }
    }

    /// Queues motion. Clicks do not come through here: see `click`.
    public func move(dx: Double, dy: Double, dt: Double) {
        moveDX += dx
        moveDY += dy
        moveDT += dt
    }

    public func scroll(dx: Double, dy: Double) {
        scrollDX += dx
        scrollDY += dy
    }

    /// Sent at once and never merged. A click is a discrete intention; motion
    /// is a quantity, and only a quantity can be summed.
    public func click(_ button: WatchButton) {
        flush()
        send(.click(button))
    }

    /// Holds a button down or lets it go. The motion queued before it goes
    /// first: a release that overtook the last move would let go of a
    /// selection one step short.
    public func button(_ button: WatchButton, down: Bool) {
        flush()
        send(.button(button, down: down))
    }

    /// Asks the phone to switch to another of its computers.
    public func pick(_ computer: KnownComputer) {
        let session = WCSession.default
        guard session.isReachable else { return }
        session.sendMessage([pickKey: computer.id], replyHandler: nil, errorHandler: nil)
    }

    /// Asks the phone app to be running. Does nothing if it already is.
    ///
    /// A queued transfer rather than a message: a message needs the app to be
    /// reachable, and it is unreachable exactly when it is not running, which
    /// is the case this exists for. The transfer is delivered by launching the
    /// app in the background — unless the user swiped it out of the app
    /// switcher, in which case nothing will, and the watch has to say so.
    public func wakePhone() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, !session.isReachable else { return }
        guard Date().timeIntervalSince(lastWake) > 5 else { return }
        lastWake = Date()
        // Undelivered transfers pile up, and a phone that comes back later
        // would otherwise be woken once for each.
        for transfer in session.outstandingUserInfoTransfers where transfer.userInfo[wakeKey] != nil {
            transfer.cancel()
        }
        session.transferUserInfo([wakeKey: true])
    }

    private func flush() {
        if moveDX != 0 || moveDY != 0 {
            send(.move(dx: moveDX, dy: moveDY, dt: moveDT))
            moveDX = 0; moveDY = 0; moveDT = 0
        }
        if scrollDX != 0 || scrollDY != 0 {
            send(.scroll(dx: scrollDX, dy: scrollDY))
            scrollDX = 0; scrollDY = 0
        }
    }

    /// A lost delta is made good by the next one — motion is a quantity, and
    /// the next message carries the rest of it — so failures are not retried.
    private func send(_ event: WatchEvent) {
        let session = WCSession.default
        guard session.isReachable else { return }
        session.sendMessage(event.payload, replyHandler: nil, errorHandler: nil)
    }
}

// MARK: - Phone side

#if os(iOS)
/// The phone's end: receives the watch's events and requests, and tells it
/// what the phone is doing.
@MainActor
public final class WatchReceiver {
    /// Every event the watch sends.
    public var onEvent: (@MainActor (WatchEvent) -> Void)?
    /// The watch asking to switch to the computer with this id.
    public var onPick: (@MainActor (String) -> Void)?
    /// The watch wants the cursor and the phone app was not running. A launch
    /// delivered through this is silent: no window, no scene, so whatever
    /// needs doing has to be done from here.
    public var onWake: (@MainActor () -> Void)?

    private let delegate = SessionDelegate()

    /// What the watch should be told, and what it has been told. Separate
    /// because they happen at different times: activation is asynchronous,
    /// and the first status is ready well before the session can carry it.
    /// Dropping it then meant a phone that was already connected never told
    /// the watch, and nothing changed to prompt a second try.
    private var wanted = PhoneStatus()
    private var sent: PhoneStatus?

    public init() {}

    public func activate() {
        guard WCSession.isSupported() else { return }
        delegate.onEvent = { [weak self] in self?.onEvent?($0) }
        delegate.onPick = { [weak self] in self?.onPick?($0) }
        delegate.onWake = { [weak self] in self?.onWake?() }
        delegate.onActivated = { [weak self] in self?.flush(force: true) }
        // A watch that has just come within reach may have launched since the
        // last status was sent.
        delegate.onReachability = { [weak self] reachable in
            if reachable { self?.flush(force: true) }
        }

        let session = WCSession.default
        session.delegate = delegate
        session.activate()
    }

    /// Application context: latest-wins, kept by the system for a watch app
    /// that is not running, and free when nothing changed.
    public func publish(_ status: PhoneStatus) {
        wanted = status
        flush(force: false)
    }

    private func flush(force: Bool) {
        guard force || wanted != sent else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        do {
            try session.updateApplicationContext(wanted.payload)
            sent = wanted
        } catch {
            print("watch context: \(error)")
        }
    }
}
#endif

#endif
