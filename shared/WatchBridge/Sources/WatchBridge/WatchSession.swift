#if canImport(WatchConnectivity)

import Foundation
import WatchConnectivity

/// Marks the transfer whose only purpose is to get the phone app running.
let wakeKey = "wake"
/// Marks the message asking the phone to switch to another computer.
let pickKey = "pick"
/// Marks the watch's heartbeat, which the phone answers with its status.
let pingKey = "ping"

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
    var onPing: (@MainActor () -> Void)?

    /// What the phone answers a heartbeat with. The reply handler runs on
    /// WatchConnectivity's queue and must be called there, so the answer is
    /// kept here, ready, rather than fetched from the main actor.
    var reply: PhoneStatus? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    private let lock = NSLock()
    private var stored: PhoneStatus?
    private var lastMessage = Date.distantPast

    /// How long the watch can go quiet before its next message means this
    /// app was probably suspended in between. The watch checks in at least
    /// every two seconds while it is awake.
    static let suspensionGap: TimeInterval = 6

    /// The answer for a message arriving now. Usually the snapshot; but after
    /// a long silence this app has most likely just been woken from
    /// suspension, and whether the tunnel survived is not known yet — the
    /// snapshot's "connected" is from before. Saying so on the very first
    /// answer is what lets the watch show "reconnecting" instead of a green
    /// light over a link that may be dead.
    private func answer() -> PhoneStatus? {
        lock.withLock {
            let now = Date()
            let gap = now.timeIntervalSince(lastMessage)
            lastMessage = now
            guard var status = stored else { return nil }
            if gap > Self.suspensionGap && gap < .infinity && status.phase == .connected {
                status.phase = .connecting
                status.note = "reconnecting"
            }
            return status
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {
        if let error { print("watch session: \(error)") }
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

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let address = message[pickKey] as? String {
            Task { @MainActor in self.onPick?(address) }
            return
        }
        guard let event = WatchEvent(payload: message) else { return }
        Task { @MainActor in self.onEvent?(event) }
    }

    /// Every message from the watch expects an answer, and gets the phone's
    /// current status. Answering is the point: a reply proves the phone app
    /// is running and handling messages *now*, which nothing else does — on
    /// the watch, `isReachable` only means the iPhone is nearby. And waiting
    /// for each answer before sending the next is what keeps WatchConnectivity
    /// from being asked for more than it can carry.
    ///
    /// Answered on the spot, on WatchConnectivity's queue, from the snapshot:
    /// the handler is not Sendable and must not wait for the main actor.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler(answer()?.payload ?? [:])
        // Any message is the watch checking in, not only a heartbeat: while
        // the cursor is moving, the events are the heartbeat.
        Task { @MainActor in self.onPing?() }
        if message[pingKey] != nil {
            return
        } else if let address = message[pickKey] as? String {
            Task { @MainActor in self.onPick?(address) }
        } else if let event = WatchEvent(payload: message) {
            Task { @MainActor in self.onEvent?(event) }
        }
    }

    /// The watch asking the phone app to be running. Queued transfers are
    /// delivered by launching the app if it is not running, which plain
    /// messages cannot do — they need the app to be reachable already, and it
    /// is not reachable precisely when it is not running.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard userInfo[wakeKey] != nil else { return }
        BridgeLog.note("wake transfer received")
        Task { @MainActor in self.onWake?() }
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        guard let status = PhoneStatus(payload: context) else { return }
        Task { @MainActor in self.onStatus?(status) }
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
    /// Whether the iPhone is nearby. Not whether the app is running — see
    /// `alive`.
    @Published public private(set) var reachable = false

    /// Whether the phone app has answered lately. This, not `reachable`, is
    /// what says the phone app is actually there: on the watch, `isReachable`
    /// is true whenever the iPhone is nearby, whether or not the app runs.
    @Published public private(set) var alive = false {
        didSet { if alive != oldValue { BridgeLog.note("phone app \(alive ? "answering" : "silent")") } }
    }

    /// What the phone last said, or nil if it has said nothing yet. A phone
    /// that has never reported and a phone reporting no computer look alike
    /// on the wrist, and are completely different faults.
    @Published public private(set) var status: PhoneStatus?

    /// False from waking after a long sleep until the phone's first answer.
    /// Everything known about the phone then is from before the sleep, and
    /// the phone app has very likely been suspended in the meantime: showing
    /// that old "connected" as green, while the phone wakes and re-checks its
    /// link, is how the cursor came to lag five or ten seconds behind a
    /// green light.
    @Published public private(set) var confirmed = true

    private let delegate = SessionDelegate()
    private var timer: Task<Void, Never>?
    private var inactiveSince: Date?

    /// Failures since the last success, for the log: the first is written at
    /// once, the rest as a count, so a link failing at speed does not bury
    /// everything else.
    private var failures = 0
    private var lastFailureLog = Date.distantPast
    private var lastError = ""

    /// A sleep this short is a turned wrist, not a suspended phone app.
    private let longSleep: TimeInterval = 10
    private var lastWake = Date.distantPast
    private var lastReply = Date.distantPast

    /// Events waiting to go, in order, and the one on the wire.
    ///
    /// One at a time, each waiting for the phone's answer. Sending at a fixed
    /// 30 Hz without waiting outran the link whenever Bluetooth slowed: the
    /// messages queued up underneath WatchConnectivity until it started
    /// failing every send with a generic IDS error, and kept failing after
    /// the phone app was restarted. Waiting means the link sets the pace —
    /// fast when it is fast — and motion that arrives meanwhile merges into
    /// one message rather than queueing behind the others.
    private var queue: [WatchEvent] = []
    private var inFlight: Int?
    private var sentAt = Date.distantPast
    private var generation = 0

    /// The interval after which an unanswered message is given up on, so
    /// that one lost reply does not stop everything behind it.
    private let replyTimeout: TimeInterval = 3

    /// How long without any answer before a heartbeat is sent, and before the
    /// phone app counts as gone. Two missed beats, plus slack for a phone app
    /// that has to be woken to answer.
    private let pingEvery: TimeInterval = 2
    private let aliveFor: TimeInterval = 5

    /// Whether the watch app is in front and awake. While it is not —
    /// the wrist is down, the screen asleep — the system throttles or
    /// suspends this app, nothing is sent, and silence from the phone means
    /// nothing. Treating it as an answer once showed "open the phone app" on
    /// every sleep, for a phone app that was there all along.
    private var active = true
    private var resumedAt = Date.distantPast

    public init() {}

    public func activate() {
        guard WCSession.isSupported(), timer == nil else { return }
        delegate.onReachability = { [weak self] in
            self?.reachable = $0
            if $0 { self?.pump() }
        }
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
        if let since = inactiveSince, Date().timeIntervalSince(since) > longSleep {
            confirmed = false
        }
        inactiveSince = nil
        // Back from sleep: ask at once, and give the answer the usual time to
        // arrive before the silence before it counts against the phone.
        resumedAt = Date()
        queue.removeAll()
        inFlight = nil
        enqueue(nil)
    }

    // MARK: Input

    public func move(dx: Double, dy: Double, dt: Double) {
        enqueue(.move(dx: dx, dy: dy, dt: dt))
    }

    public func scroll(dx: Double, dy: Double) {
        enqueue(.scroll(dx: dx, dy: dy))
    }

    /// Never merged. A click is a discrete intention; motion is a quantity,
    /// and only a quantity can be summed.
    public func click(_ button: WatchButton) {
        enqueue(.click(button))
    }

    /// In order behind the motion before it: a release that overtook the last
    /// move would let go of a selection one step short.
    public func button(_ button: WatchButton, down: Bool) {
        enqueue(.button(button, down: down))
    }

    /// Asks the phone to switch to another of its computers.
    public func pick(_ computer: KnownComputer) {
        send([pickKey: computer.id])
    }

    // MARK: Sending

    /// Queues an event — nil for a heartbeat — and sends if nothing is out.
    private func enqueue(_ event: WatchEvent?) {
        if let event {
            if let last = queue.last, let merged = Self.merge(last, event) {
                queue[queue.count - 1] = merged
            } else {
                queue.append(event)
            }
        }
        if event == nil && inFlight == nil && queue.isEmpty {
            send([pingKey: true])
        } else {
            pump()
        }
    }

    private func pump() {
        guard inFlight == nil, !queue.isEmpty else { return }
        send(queue.removeFirst().payload)
    }

    private func send(_ message: [String: Any]) {
        let session = WCSession.default
        guard active, session.activationState == .activated, session.isReachable else {
            queue.removeAll()
            return
        }
        // Defensive: the delegate is what receives replies, and nothing else
        // should replace it — but if anything ever does, this says so.
        if session.delegate !== delegate {
            BridgeLog.note("session delegate was replaced; restoring")
            session.delegate = delegate
        }
        generation += 1
        let tag = generation
        inFlight = tag
        sentAt = Date()

        // Spelled out as @Sendable: WatchConnectivity calls these on its own
        // queue, and a closure formed inside a main-actor type that captures
        // it is otherwise inferred to be main-actor and traps on entry.
        let answered: @Sendable ([String: Any]) -> Void = { [weak self] reply in
            let status = PhoneStatus(payload: reply)
            Task { @MainActor in self?.finished(tag, answer: status, ok: true) }
        }
        let failed: @Sendable (Error) -> Void = { [weak self] error in
            let text = SessionDelegate.describe(error)
            Task { @MainActor in
                self?.noteFailure(text)
                self?.finished(tag, answer: nil, ok: false)
            }
        }
        session.sendMessage(message, replyHandler: answered, errorHandler: failed)
    }

    private func noteFailure(_ text: String) {
        failures += 1
        lastError = text
        let now = Date()
        if failures == 1 || now.timeIntervalSince(lastFailureLog) > 5 {
            BridgeLog.note("send failed (\(failures) since last success): \(text); \(SessionDelegate.describe(WCSession.default))")
            lastFailureLog = now
        }
    }

    private func finished(_ tag: Int, answer: PhoneStatus?, ok: Bool) {
        // A message given up on by the timeout may still answer later; it is
        // good news about the phone, but no longer what is in flight.
        if ok {
            if failures > 0 {
                BridgeLog.note("send succeeded after \(failures) failures")
                failures = 0
            }
            lastReply = Date()
            alive = true
            confirmed = true
            // An empty answer is a phone app that has not worked out its
            // status yet; keep what was there.
            if let answer { status = answer }
        }
        guard inFlight == tag else { return }
        inFlight = nil
        // Lost motion is made good by the next message, which carries the
        // rest of it, so a failure is not retried; the queue just moves on.
        pump()
    }

    /// Twice a second: give up on a reply that is not coming, send a
    /// heartbeat when the link has been quiet, decide whether the phone app
    /// is still there, and ask it to be when it is not.
    private func tick() {
        guard active else { return }
        let now = Date()
        if let tag = inFlight, now.timeIntervalSince(sentAt) > replyTimeout {
            noteFailure("no reply in \(Int(replyTimeout))s")
            finished(tag, answer: nil, ok: false)
        }
        let heardFrom = max(lastReply, resumedAt)
        if alive && now.timeIntervalSince(heardFrom) > aliveFor { alive = false }
        if inFlight == nil && queue.isEmpty && now.timeIntervalSince(max(lastReply, sentAt)) >= pingEvery {
            enqueue(nil)
        }
        if !alive { wakePhone() }
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
    /// reachable, and it is unreachable exactly when it is not running, which
    /// is the case this exists for. The transfer is delivered by launching the
    /// app in the background — unless the user swiped it out of the app
    /// switcher, in which case nothing will, and the watch has to say so.
    private func wakePhone() {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        guard Date().timeIntervalSince(lastWake) > 5 else { return }
        lastWake = Date()
        // Undelivered transfers pile up, and a phone that comes back later
        // would otherwise be woken once for each.
        for transfer in session.outstandingUserInfoTransfers where transfer.userInfo[wakeKey] != nil {
            transfer.cancel()
        }
        session.transferUserInfo([wakeKey: true])
        BridgeLog.note("wake transfer queued; \(SessionDelegate.describe(session))")
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
    /// A message from the watch arrived, already answered. For noticing
    /// that the app has just been woken from suspension.
    public var onPing: (@MainActor () -> Void)?

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
        delegate.onPing = { [weak self] in self?.onPing?() }
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

    /// One line of what the session believes, for the app's log.
    public var sessionState: String {
        guard WCSession.isSupported() else { return "unsupported" }
        let session = WCSession.default
        let ours = session.delegate === delegate ? "ours" : "REPLACED"
        return SessionDelegate.describe(session) + ", delegate \(ours)"
    }

    /// Application context: latest-wins, kept by the system for a watch app
    /// that is not running, and free when nothing changed.
    public func publish(_ status: PhoneStatus) {
        delegate.reply = status
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
