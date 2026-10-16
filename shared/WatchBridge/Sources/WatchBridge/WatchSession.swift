#if canImport(WatchConnectivity)

import Foundation
import WatchConnectivity

/// Marks the transfer whose only purpose is to get the phone app running.
let wakeKey = "wake"
/// Marks a wake sent because the watch has just woken from a long sleep,
/// rather than because the phone stopped answering. The phone restarts a
/// stale background process for either, but only the second is a sign of
/// trouble worth a banner when the app is in front.
let freshKey = "fresh"
/// Marks the message asking the phone to switch to another computer.
let pickKey = "pick"
/// Marks the watch's heartbeat, which the phone answers with its status.
let pingKey = "ping"
/// When the phone wrote a status it pushed as application context, so that
/// the watch can tell a push made just now from one delivered late.
let atKey = "at"

/// Forwards WCSession's callbacks, which arrive on a background queue, to
/// closures that hop to the main actor. Kept apart from the types that use it
/// so that neither of them has to pretend the delegate is main-actor.
final class SessionDelegate: NSObject, WCSessionDelegate, @unchecked Sendable {
    var onEvent: (@MainActor (WatchEvent) -> Void)?
    var onPick: (@MainActor (String) -> Void)?
    /// A status from the phone, and whether it was pushed just now — which
    /// makes it evidence that the phone app is running, as a reply is.
    var onStatus: (@MainActor (PhoneStatus, _ current: Bool) -> Void)?
    var onReachability: (@MainActor (Bool) -> Void)?
    var onActivated: (@MainActor () -> Void)?
    var onWake: (@MainActor (_ fresh: Bool) -> Void)?
    /// A message arrived, after this much silence since the one before.
    var onMessage: (@MainActor (_ gap: TimeInterval) -> Void)?

    /// Set by the phone app: what to do instead of handling a message, when
    /// the first one after a long silence reaches a process that has been
    /// running in the background. Ends the process; see `staleGap`.
    var onStale: (@Sendable (TimeInterval) -> Void)?

    /// What the phone answers a heartbeat with. Reply handlers run on
    /// WatchConnectivity's queue and must be called there, so the answer is
    /// kept here, ready, rather than fetched from the main actor.
    var reply: PhoneStatus? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    private let lock = NSLock()
    private var stored: PhoneStatus?
    private var lastMessage = Date.distantPast
    private let started = Date()
    private var background = false

    /// Whether the phone app is in the background, kept here because the
    /// decision is made on WatchConnectivity's queue, where UIApplication
    /// cannot be asked.
    func setInBackground(_ value: Bool) {
        lock.withLock { background = value }
    }

    /// How long the watch can go quiet before its next message means this
    /// app was probably suspended in between. The watch checks in at least
    /// every two seconds while it is awake.
    static let suspensionGap: TimeInterval = 6

    /// A silence this long means the watch has just woken from a sleep. A
    /// phone process that sat through it in the background is the kind whose
    /// messaging stalls soon after, so rather than carry on until it does, it
    /// ends, and the wake request the watch sends on waking launches a fresh
    /// one. A process a few seconds old is that fresh one, and carries on.
    static let staleGap: TimeInterval = 10
    static let freshFor: TimeInterval = 10

    /// Whether this process started only moments ago — the replacement the
    /// watch has just launched, rather than one that has been sitting around.
    var processIsFresh: Bool {
        Date().timeIntervalSince(started) <= Self.freshFor
    }

    /// Notes a message's arrival. Returns the silence before it, and whether
    /// this process should end instead of handling it.
    private func arrived() -> (gap: TimeInterval, stale: Bool) {
        lock.withLock {
            let now = Date()
            let gap = now.timeIntervalSince(lastMessage)
            lastMessage = now
            let stale = background && gap > Self.staleGap && gap < .infinity
                && now.timeIntervalSince(started) > Self.freshFor && onStale != nil
            return (gap, stale)
        }
    }

    /// The snapshot, except after a silence long enough that this app was
    /// probably suspended: then whether the tunnel survived is not known yet,
    /// and the snapshot's "connected" is from before.
    private func status(after gap: TimeInterval) -> PhoneStatus? {
        guard var status = reply else { return nil }
        if gap > Self.suspensionGap && gap < .infinity && status.phase == .connected {
            status.phase = .connecting
            status.note = "reconnecting"
        }
        return status
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {
        let reachable = session.isReachable
        let activated = state == .activated
        BridgeLog.note("activation done: state \(state.rawValue), error \(error.map(Self.describe) ?? "none"), \(Self.describe(session))")
        Task { @MainActor in
            self.onReachability?(reachable)
            if activated { self.onActivated?() }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        BridgeLog.note("reachability changed: \(Self.describe(session))")
        Task { @MainActor in self.onReachability?(reachable) }
    }

    /// An event or a pick, sent without asking for a reply. Events do not
    /// wait on answers: replies from the phone to the watch have been seen to
    /// stop arriving while messages the other way kept getting through, and
    /// input that waited on them stopped with them.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let (gap, stale) = arrived()
        if stale { return end(after: gap) }
        handle(message, after: gap)
    }

    /// A heartbeat, answered on the spot from the snapshot — the handler is
    /// not Sendable and must not wait for the main actor. A reply proves the
    /// phone app is running and handling messages now, which nothing else
    /// does: on the watch, `isReachable` only means the iPhone is nearby.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        let (gap, stale) = arrived()
        // No answer from a stale process: the next one comes from its
        // replacement, which is what the watch is waiting for.
        if stale { return end(after: gap) }
        replyHandler(status(after: gap)?.payload ?? [:])
        handle(message, after: gap)
    }

    private func end(after gap: TimeInterval) {
        onStale?(gap)
    }

    private func handle(_ message: [String: Any], after gap: TimeInterval) {
        // Any message is the watch checking in, events included.
        Task { @MainActor in self.onMessage?(gap) }
        if message[pingKey] != nil { return }
        if let address = message[pickKey] as? String {
            Task { @MainActor in self.onPick?(address) }
        } else if let event = WatchEvent(payload: message) {
            Task { @MainActor in self.onEvent?(event) }
        }
    }

    /// The watch asking the phone app to be running. Queued transfers are
    /// delivered by launching the app if it is not running, which plain
    /// messages cannot do.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard userInfo[wakeKey] != nil else { return }
        let fresh = userInfo[freshKey] != nil
        BridgeLog.note(fresh ? "wake transfer received (watch woke from sleep)" : "wake transfer received")
        Task { @MainActor in self.onWake?(fresh) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        guard let status = PhoneStatus(payload: context) else { return }
        // Pushed within the last few seconds, by the phone's clock — the two
        // are kept in step by the pairing. An old context delivered late says
        // nothing about whether the phone app is running now.
        let at = context[atKey] as? Double ?? 0
        let current = abs(Date().timeIntervalSince1970 - at) < 5
        Task { @MainActor in self.onStatus?(status, current) }
    }

    #if os(iOS)
    // Required on iOS, where one watch can be swapped for another.
    func sessionDidBecomeInactive(_ session: WCSession) {
        BridgeLog.note("session became inactive")
    }
    func sessionDidDeactivate(_ session: WCSession) {
        BridgeLog.note("session deactivated; activating again")
        session.activate()
    }
    #endif

    /// One line of what a session believes about the other side.
    static func describe(_ session: WCSession) -> String {
        var parts = ["activation \(session.activationState.rawValue)", "reachable \(session.isReachable)"]
        #if os(iOS)
        parts += ["paired \(session.isPaired)", "watch app installed \(session.isWatchAppInstalled)"]
        #else
        parts += ["companion installed \(session.isCompanionAppInstalled)"]
        #endif
        return parts.joined(separator: ", ")
    }

    static func describe(_ error: Error) -> String {
        let e = error as NSError
        var text = "\(e.domain) \(e.code)"
        if let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " <- \(underlying.domain) \(underlying.code)"
        }
        return text
    }
}

// MARK: - Watch side

/// The watch's end: sends events to the phone app, and knows whether it is
/// there and what it is doing.
@MainActor
public final class PhoneLink: ObservableObject {
    /// Whether the phone app has been heard from lately — a heartbeat answered
    /// or a status pushed just now. This, not WatchConnectivity's
    /// `isReachable` — which on a watch means only that the iPhone is nearby —
    /// says the phone app is actually there.
    @Published public private(set) var alive = false {
        didSet { if alive != oldValue { BridgeLog.note("phone app \(alive ? "heard from" : "silent")") } }
    }

    /// What the phone last said, or nil if it has said nothing yet.
    @Published public private(set) var status: PhoneStatus?

    /// False from waking after a long sleep until the phone is heard from
    /// again. What was known then is from before the sleep, and the phone app
    /// has very likely been suspended meanwhile.
    @Published public private(set) var confirmed = true

    private let delegate = SessionDelegate()
    private var timer: Task<Void, Never>?

    /// Motion waiting to go, merged; and what is not motion, in order.
    ///
    /// Sent without waiting for answers, at most one message every 50 ms.
    /// Waiting for each answer was the earlier design, and it tied input to
    /// the one direction of WatchConnectivity that has been seen to fail on
    /// its own: replies from the phone stopped arriving while the watch's
    /// messages kept getting through, and the cursor stopped with them. The
    /// 50 ms gap is what keeps the rate down instead — twenty a second at
    /// most, with motion in between merging into the next message, so no
    /// distance is lost.
    private var queue: [WatchEvent] = []
    private var pumpScheduled = false
    private var lastSent = Date.distantPast
    private let minimumGap: TimeInterval = 0.05

    /// Heartbeats: one outstanding at a time, every couple of seconds.
    private var pingOut = false
    private var pingSentAt = Date.distantPast
    private let pingEvery: TimeInterval = 2
    private let pingTimeout: TimeInterval = 3

    private var lastHeard = Date.distantPast
    /// Two missed beats, plus slack for a phone app that has to be woken.
    private let aliveFor: TimeInterval = 5

    /// Wake requests back off: every unanswered one costs a queued transfer
    /// on the same link the messages use, and a link already struggling was
    /// being sent one every three seconds.
    private var lastWake = Date.distantPast
    private var wakeDelay: TimeInterval = 3
    private let firstWakeAfter: TimeInterval = 2.5
    private let maxWakeDelay: TimeInterval = 30

    /// Whether the watch app is in front and awake. Asleep, the system
    /// throttles or suspends this app, nothing is sent, and silence from the
    /// phone means nothing.
    private var active = true
    private var startedAt = Date.distantPast
    private var resumedAt = Date.distantPast
    private var inactiveSince: Date?

    /// A sleep this short is a turned wrist, not a suspended phone app. A
    /// little under the phone's `staleGap`, so that whenever the phone is
    /// going to start afresh the watch is already showing "reconnecting".
    private let longSleep: TimeInterval = 8

    /// For the log.
    private var sentCount = 0
    private var failures = 0
    private var lastRateLog = Date()
    private var lastFailureLog = Date.distantPast

    public init() {}

    public func activate() {
        guard WCSession.isSupported(), timer == nil else { return }
        startedAt = Date()
        // In reach again: send what queued up meanwhile. Being in reach says
        // only that the iPhone is nearby, not that the app is running, so it
        // decides nothing else.
        delegate.onReachability = { [weak self] in
            if $0 { self?.pump() }
        }
        delegate.onStatus = { [weak self] status, current in
            self?.status = status
            if current { self?.heard(via: "status push") }
        }
        // The status the phone sent while this app was not running waits in
        // the session, but only once the session is up.
        delegate.onActivated = { [weak self] in self?.loadStoredStatus() }

        let session = WCSession.default
        session.delegate = delegate
        session.activate()
        loadStoredStatus()

        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.tick()
            }
        }
    }

    /// Tells the link whether the watch app is in front and awake.
    public func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        BridgeLog.note(active ? "watch app active" : "watch app inactive")
        guard active else {
            inactiveSince = Date()
            return
        }
        let slept = inactiveSince.map { Date().timeIntervalSince($0) } ?? 0
        inactiveSince = nil
        resumedAt = Date()
        queue.removeAll()
        pingOut = false
        if slept > longSleep {
            // The phone app has most likely been sitting suspended, and will
            // end itself rather than answer (see SessionDelegate.staleGap).
            // Ask for its replacement now rather than after the usual wait.
            confirmed = false
            wakePhone(fresh: true)
        }
        ping()
    }

    // MARK: Input

    public func move(dx: Double, dy: Double, dt: Double) { enqueue(.move(dx: dx, dy: dy, dt: dt)) }
    public func scroll(dx: Double, dy: Double) { enqueue(.scroll(dx: dx, dy: dy)) }
    /// Never merged: a click is a discrete intention, and only motion is a
    /// quantity that can be summed.
    public func click(_ button: WatchButton) { enqueue(.click(button)) }
    /// In order behind the motion before it: a release that overtook the last
    /// move would let go of a selection one step short.
    public func button(_ button: WatchButton, down: Bool) { enqueue(.button(button, down: down)) }

    /// Asks the phone to switch to another of its computers.
    public func pick(_ computer: KnownComputer) {
        send([pickKey: computer.id])
    }

    // MARK: Sending

    private func enqueue(_ event: WatchEvent) {
        if let last = queue.last, let merged = Self.merge(last, event) {
            queue[queue.count - 1] = merged
        } else {
            queue.append(event)
        }
        pump()
    }

    private func pump() {
        guard !queue.isEmpty else { return }
        let wait = minimumGap - Date().timeIntervalSince(lastSent)
        guard wait <= 0 else {
            guard !pumpScheduled else { return }
            pumpScheduled = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                self?.pumpScheduled = false
                self?.pump()
            }
            return
        }
        send(queue.removeFirst().payload)
        if !queue.isEmpty { pump() }
    }

    /// Fire and forget. A lost move is made good by the next one, which
    /// carries the rest of the distance.
    private func send(_ message: [String: Any]) {
        let session = WCSession.default
        guard active, session.activationState == .activated, session.isReachable else {
            queue.removeAll()
            return
        }
        lastSent = Date()
        sentCount += 1
        let failed: @Sendable (Error) -> Void = { [weak self] error in
            let text = SessionDelegate.describe(error)
            Task { @MainActor in self?.noteFailure(text) }
        }
        session.sendMessage(message, replyHandler: nil, errorHandler: failed)
    }

    /// Asks the phone for its status and waits for the answer — the one
    /// message that does.
    private func ping() {
        let session = WCSession.default
        guard active, !pingOut, session.activationState == .activated, session.isReachable else { return }
        pingOut = true
        pingSentAt = Date()

        // Spelled out as @Sendable: WatchConnectivity calls these on its own
        // queue, and a closure formed inside a main-actor type that captures
        // it is otherwise inferred to be main-actor and traps on entry.
        let answered: @Sendable ([String: Any]) -> Void = { [weak self] reply in
            let status = PhoneStatus(payload: reply)
            Task { @MainActor in
                guard let self else { return }
                self.pingOut = false
                if let status { self.status = status }
                self.heard(via: "reply")
            }
        }
        let failed: @Sendable (Error) -> Void = { [weak self] error in
            let text = SessionDelegate.describe(error)
            Task { @MainActor in
                self?.pingOut = false
                self?.noteFailure("heartbeat: \(text)")
            }
        }
        session.sendMessage([pingKey: true], replyHandler: answered, errorHandler: failed)
    }

    /// Something came back from the phone app just now.
    private func heard(via channel: String) {
        if failures > 0 {
            BridgeLog.note("heard from phone by \(channel) after \(failures) failures")
            failures = 0
        }
        lastHeard = Date()
        alive = true
        confirmed = true
        wakeDelay = 3
    }

    private func noteFailure(_ text: String) {
        failures += 1
        let now = Date()
        if failures == 1 || now.timeIntervalSince(lastFailureLog) > 5 {
            BridgeLog.note("failure (\(failures) since last heard): \(text); \(SessionDelegate.describe(WCSession.default))")
            lastFailureLog = now
        }
    }

    /// Twice a second: give up on a heartbeat that is not coming back, send
    /// the next, decide whether the phone app is still there, and ask it to
    /// be when it is not.
    private func tick() {
        guard active else { return }
        let now = Date()
        if now.timeIntervalSince(lastRateLog) >= 5 {
            if sentCount > 0 {
                BridgeLog.note(String(format: "sent %d messages in %.0fs", sentCount, now.timeIntervalSince(lastRateLog)))
            }
            sentCount = 0
            lastRateLog = now
        }
        if pingOut && now.timeIntervalSince(pingSentAt) > pingTimeout {
            pingOut = false
            noteFailure("heartbeat: no reply in \(Int(pingTimeout))s")
        }
        if now.timeIntervalSince(pingSentAt) >= pingEvery { ping() }

        let heardFrom = max(lastHeard, resumedAt, startedAt)
        let silence = now.timeIntervalSince(heardFrom)
        if alive && silence > aliveFor { alive = false }
        if silence > firstWakeAfter && now.timeIntervalSince(lastWake) >= wakeDelay {
            wakePhone()
            wakeDelay = min(wakeDelay * 2, maxWakeDelay)
        }
    }

    /// Two moves in a row are sent as one, and two scrolls: ten small moves
    /// and their sum land the cursor in the same place. Nothing else merges.
    private static func merge(_ a: WatchEvent, _ b: WatchEvent) -> WatchEvent? {
        switch (a, b) {
        case let (.move(ax, ay, at), .move(bx, by, bt)):
            return .move(dx: ax + bx, dy: ay + by, dt: at + bt)
        case let (.scroll(ax, ay), .scroll(bx, by)):
            return .scroll(dx: ax + bx, dy: ay + by)
        default:
            return nil
        }
    }

    private func loadStoredStatus() {
        if let stored = PhoneStatus(payload: WCSession.default.receivedApplicationContext) {
            status = stored
        }
    }

    /// Asks the phone app to be running.
    ///
    /// A queued transfer rather than a message: a message needs the app to be
    /// reachable, and it is unreachable exactly when it is not running. The
    /// transfer is delivered by launching the app in the background — unless
    /// the user swiped it out of the app switcher, in which case nothing will,
    /// and the watch has to say so.
    private func wakePhone(fresh: Bool = false) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        lastWake = Date()
        // Undelivered transfers pile up, and a phone that comes back later
        // would otherwise be woken once for each.
        for transfer in session.outstandingUserInfoTransfers where transfer.userInfo[wakeKey] != nil {
            transfer.cancel()
        }
        var request: [String: Any] = [wakeKey: true]
        if fresh { request[freshKey] = true }
        session.transferUserInfo(request)
        BridgeLog.note("wake transfer queued\(fresh ? " (after sleep)" : ""); \(SessionDelegate.describe(session))")
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
    /// The watch wants the cursor and the phone app was not answering — or,
    /// with `fresh`, the watch has just woken from a long sleep. A launch
    /// delivered through this is silent: no window, no scene, so whatever
    /// needs doing has to be done from here.
    public var onWake: (@MainActor (_ fresh: Bool) -> Void)?
    /// A message from the watch arrived, after this much silence. A long one
    /// — over `suspensionGap` — means this app was probably suspended in
    /// between, and has just been woken by the message.
    public var onMessage: (@MainActor (_ gap: TimeInterval) -> Void)?

    /// See `SessionDelegate.suspensionGap`.
    public static let suspensionGap = SessionDelegate.suspensionGap

    /// Whether this process is the fresh one the watch just launched.
    public var processIsFresh: Bool { delegate.processIsFresh }

    private let delegate = SessionDelegate()
    private var current = PhoneStatus()
    private var beats: Task<Void, Never>?

    public init() {}

    public func activate() {
        guard WCSession.isSupported() else { return }
        delegate.onEvent = { [weak self] in self?.onEvent?($0) }
        delegate.onPick = { [weak self] in self?.onPick?($0) }
        delegate.onWake = { [weak self] in self?.onWake?($0) }
        delegate.onMessage = { [weak self] in self?.onMessage?($0) }
        delegate.onActivated = { [weak self] in self?.push() }
        delegate.onReachability = { [weak self] reachable in
            if reachable { self?.push() }
        }

        let session = WCSession.default
        session.delegate = delegate
        session.activate()

        // The phone's own word that it is running, independent of replies:
        // pushed every two seconds while the watch app is open and in reach,
        // so the watch can still tell the phone app is there when answers to
        // its heartbeats stop arriving.
        beats = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if WCSession.default.isReachable { self.push() }
            }
        }
    }

    /// What to do instead of handling a message when this process has gone
    /// stale in the background; see `SessionDelegate.staleGap`. Called on
    /// WatchConnectivity's queue.
    public func onStale(_ handler: @escaping @Sendable (TimeInterval) -> Void) {
        delegate.onStale = handler
    }

    /// Whether the app is in the background, for the same decision.
    public func setInBackground(_ value: Bool) {
        delegate.setInBackground(value)
    }

    /// One line of what the session believes, for the app's log.
    public var sessionState: String {
        guard WCSession.isSupported() else { return "unsupported" }
        let session = WCSession.default
        let ours = session.delegate === delegate ? "ours" : "REPLACED"
        return SessionDelegate.describe(session) + ", delegate \(ours)"
    }

    public func publish(_ status: PhoneStatus) {
        delegate.reply = status
        guard status != current else { return }
        current = status
        push()
    }

    /// Application context: latest-wins, and kept by the system for a watch
    /// app that is not running. Stamped with the time, which both lets the
    /// watch tell a fresh push from a late one and makes every push differ —
    /// an identical context is not delivered again.
    private func push() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        var context = current.payload
        context[atKey] = Date().timeIntervalSince1970
        do {
            try session.updateApplicationContext(context)
        } catch {
            BridgeLog.note("context push failed: \(SessionDelegate.describe(error))")
        }
    }
}
#endif

#endif
