#if canImport(WatchConnectivity)

import Foundation
import WatchConnectivity

/// Marks the transfer whose only purpose is to get the phone running.
let wakeKey = "wake"

/// Forwards WCSession's callbacks, which arrive on a background queue, to
/// closures that hop to the main actor. Kept apart from the types that use it
/// so that neither of them has to pretend the delegate is main-actor.
final class SessionDelegate: NSObject, WCSessionDelegate, @unchecked Sendable {
    var onEvent: (@MainActor (WatchEvent) -> Void)?
    var onState: (@MainActor (HostState) -> Void)?
    var onCredentials: (@MainActor (HostCredentials) -> Void)?
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
        guard let event = WatchEvent(payload: message) else { return }
        Task { @MainActor in self.onEvent?(event) }
    }

    /// The watch asking the phone to be here. Queued transfers are delivered
    /// by launching the app if it is not running, which plain messages cannot
    /// do — they need the app to be reachable already, and it is not reachable
    /// precisely when it is not running.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard userInfo[wakeKey] != nil else { return }
        Task { @MainActor in self.onWake?() }
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        if let credentials = HostCredentials(payload: context) {
            let handler = onCredentials
            Task { @MainActor in handler?(credentials) }
        }
        guard let state = HostState(payload: context) else { return }
        Task { @MainActor in self.onState?(state) }
    }

    #if os(iOS)
    // Required on iOS, where one watch can be swapped for another.
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}

// MARK: - Watch side

/// The watch's end: sends events to the phone, and knows whether the phone is
/// listening.
@MainActor
public final class WatchSender: ObservableObject {
    /// Whether the phone is there at all. `sendMessage` only works while it
    /// is, which is correct for a mouse: a queued cursor movement delivered
    /// later is worse than none.
    @Published public private(set) var reachable = false

    /// What the phone last said about the host, or nil if it has not said
    /// anything yet. The difference matters: a phone that has never reported
    /// and a phone reporting no computer look identical on the wrist, and
    /// they are completely different faults.
    @Published public private(set) var host: HostState?

    /// The last credentials the phone sent, or those it sent in some earlier
    /// session: application context is kept by the system, so this is
    /// populated at activation even when the phone is switched off.
    @Published public private(set) var credentials: HostCredentials?

    /// Messages WatchConnectivity refused since this session began.
    ///
    /// WatchConnectivity is built for occasional small messages, not for a
    /// stream at pointer rates, and how much it will actually carry is the
    /// one thing about this design that cannot be settled without a watch on
    /// a wrist. Counting is what turns "it felt laggy" into a number.
    ///
    /// Sent and counted, never replied to. An earlier version measured a
    /// round trip once a second by asking for a reply, which mixed a
    /// reply-handler message into a stream of fire-and-forget ones — an
    /// unusual thing to ask of WatchConnectivity, and the first message sent
    /// was always the odd one. Latency is worth knowing but not worth being
    /// the strangest thing in the code while a crash is unexplained.
    @Published public private(set) var dropped = 0

    private let delegate = SessionDelegate()
    private var pump: Task<Void, Never>?

    /// Pending motion, summed. Deltas are far too frequent to send one
    /// message each — WatchConnectivity is not a 60 Hz pipe — so they are
    /// accumulated and flushed at a fixed rate. Summing is lossless for
    /// position: ten small moves and their total land the cursor in the same
    /// place.
    private var moveDX = 0.0, moveDY = 0.0, moveDT = 0.0
    private var scrollDX = 0.0, scrollDY = 0.0

    /// How often queued motion is flushed. 30 Hz is the most WatchConnectivity
    /// is likely to carry; `dropped` says whether even that was optimistic.
    public var interval: Duration = .milliseconds(33)

    public init() {}

    public func activate() {
        guard WCSession.isSupported() else { return }
        delegate.onReachability = { [weak self] in self?.reachable = $0 }
        delegate.onState = { [weak self] in self?.host = $0 }
        delegate.onCredentials = { [weak self] in self?.credentials = $0 }

        // A context sent while this app was not running waits in the session,
        // but only once the session is up. Reading it on the line after
        // activate() is reading it too early: activation is asynchronous, and
        // what comes back then is empty. That is why this reads it again when
        // activation completes, and why the first read is kept — on a session
        // that was already active, no callback is coming.
        delegate.onActivated = { [weak self] in self?.loadStoredContext() }

        let session = WCSession.default
        session.delegate = delegate
        session.activate()
        loadStoredContext()

        pump?.cancel()
        pump = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.interval ?? .milliseconds(33))
                guard let self else { return }
                self.flush()
                // While the app is open and the phone is not there, keep
                // asking. wakePhone rate-limits itself, and stops mattering
                // the moment the phone answers.
                if !self.reachable { self.wakePhone() }
            }
        }
    }

    /// Takes whatever the phone last sent, from whenever it last sent it.
    /// Never clears: an empty context means the session has nothing to say
    /// yet, not that the computer has gone.
    private func loadStoredContext() {
        let stored = WCSession.default.receivedApplicationContext
        if let state = HostState(payload: stored) { host = state }
        if let credentials = HostCredentials(payload: stored) { self.credentials = credentials }
    }

    public func deactivate() {
        pump?.cancel()
        pump = nil
        moveDX = 0; moveDY = 0; moveDT = 0
        scrollDX = 0; scrollDY = 0
    }

    /// Clears the delivery counter, so a session's numbers describe that
    /// session.
    public func resetStats() {
        dropped = 0
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
        send(.click(button))
    }

    /// Holds a button down or lets it go. Sent at once like a click, not
    /// batched: a press that arrives after the movement it was meant to
    /// start is a drag that selected the wrong thing.
    public func button(_ button: WatchButton, down: Bool) {
        send(.button(button, down: down))
    }

    /// Asks the phone to be running. Does nothing if it already is.
    ///
    /// A queued transfer rather than a message: a message needs the phone to
    /// be reachable, and it is unreachable exactly when it is not running,
    /// which is the case this exists for. The transfer is delivered by
    /// launching the app in the background.
    public func wakePhone() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, !session.isReachable else { return }
        guard Date().timeIntervalSince(lastWake) > 5 else { return }
        lastWake = Date()
        session.transferUserInfo([wakeKey: true])
    }

    private var lastWake = Date.distantPast

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

    private func send(_ event: WatchEvent) {
        let session = WCSession.default
        guard session.isReachable else { return }

        // A lost delta is made good by the next one — motion is a quantity,
        // and the next message carries where the cursor should be. Losses are
        // counted rather than reported: at pointer rates a log line per miss
        // would itself be the problem.
        //
        // The error handler runs on WatchConnectivity's own queue, so it does
        // nothing but hand the count to the main actor.
        session.sendMessage(event.payload, replyHandler: nil) { [weak self] _ in
            Task { @MainActor in self?.dropped += 1 }
        }
    }
}

// MARK: - Phone side

/// The phone's end: receives the watch's events and tells it what the host is
/// doing.
@MainActor
public final class PhoneReceiver: ObservableObject {
    @Published public private(set) var watchReachable = false

    /// Called for every event the watch sends, on the main actor.
    public var onEvent: (@MainActor (WatchEvent) -> Void)?

    /// The watch wants to use the cursor and the phone was not running. A
    /// launch delivered through this is silent: no window, no scene, so
    /// whatever needs doing has to be done from here.
    public var onWake: (@MainActor () -> Void)?

    private let delegate = SessionDelegate()

    /// What the watch should be told, and what it has been told. They are
    /// separate because the two happen at different times: activation is
    /// asynchronous, and the first state to publish is ready well before the
    /// session can carry it.
    private var wanted = HostState()
    private var sent: HostState?

    /// Sent in the same context as the state, because WCSession keeps only
    /// one: writing them separately would mean each overwrote the other.
    private var credentials: HostCredentials?

    public init() {}

    public func activate() {
        guard WCSession.isSupported() else { return }
        delegate.onEvent = { [weak self] event in self?.onEvent?(event) }
        delegate.onWake = { [weak self] in self?.onWake?() }
        delegate.onReachability = { [weak self] reachable in
            guard let self else { return }
            self.watchReachable = reachable
            // A watch that has just come within reach may have launched since
            // the last context was sent, or never have seen one.
            if reachable { self.flush(force: true) }
        }
        delegate.onActivated = { [weak self] in self?.flush(force: true) }

        let session = WCSession.default
        session.delegate = delegate
        session.activate()
    }

    /// Tells the watch what the host is doing. Application context rather
    /// than a message: it is latest-wins and survives the watch being asleep,
    /// which is what a status is, and it costs nothing when unchanged.
    ///
    /// Kept rather than dropped when the session cannot carry it yet.
    /// `activate` returns before the session is usable, and the first state
    /// is ready immediately — so dropping it meant a phone that was already
    /// connected never told the watch, and nothing ever changed to prompt a
    /// second attempt.
    public func publish(_ state: HostState) {
        wanted = state
        flush(force: false)
    }

    /// Hands the watch what it needs to reach the computer by itself. Safe to
    /// call repeatedly; it only costs a transfer when something changed.
    public func publish(credentials: HostCredentials) {
        guard credentials != self.credentials else { return }
        self.credentials = credentials
        flush(force: true)
    }

    private func flush(force: Bool) {
        guard WCSession.isSupported() else { return }
        guard force || wanted != sent else { return }

        let session = WCSession.default
        guard session.activationState == .activated else { return }

        // One dictionary carries both: WCSession keeps a single context, so
        // sending them separately would mean each overwrote the other.
        var context = wanted.payload
        if let credentials {
            context.merge(credentials.payload) { _, new in new }
        } else if let last = HostCredentials(payload: session.applicationContext) {
            // Nothing to say about the computer this time, but the watch has
            // been told about one before. Sending a context without it would
            // take it away: the context replaces, it does not merge, and the
            // watch has no other source for an address.
            context.merge(last.payload) { _, new in new }
        }

        do {
            try session.updateApplicationContext(context)
            sent = wanted
        } catch {
            // Worth saying: a context that will not go is exactly the failure
            // that leaves the watch showing no host with no other sign.
            print("watch context: \(error)")
        }
    }
}

#endif
