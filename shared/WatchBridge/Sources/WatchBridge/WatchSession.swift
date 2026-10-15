#if canImport(WatchConnectivity)

import Foundation
import WatchConnectivity

/// What the watch sends to ask for credentials, as a message when the phone
/// app is running and as a queued transfer when it is not.
let credentialRequestKey = "awmouse.credentials?"

/// Forwards WCSession's callbacks, which arrive on a background queue, to
/// closures that hop to the main actor. Kept apart from the types that use it
/// so that neither of them has to pretend the delegate is main-actor.
final class SessionDelegate: NSObject, WCSessionDelegate, @unchecked Sendable {
    var onCredentials: (@MainActor (HostCredentials) -> Void)?
    var onReachability: (@MainActor (Bool) -> Void)?
    var onActivated: (@MainActor () -> Void)?
    var onRequest: (@MainActor () -> Void)?

    /// What the phone answers a request with. A request arrives as a message
    /// with a reply handler, on WatchConnectivity's queue, and the handler is
    /// neither Sendable nor willing to wait — so the answer is read from here,
    /// on the spot, rather than fetched from the main actor.
    var reply: HostCredentials? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    private let lock = NSLock()
    private var stored: HostCredentials?

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

    /// The phone's side of a request made while it was running. An empty
    /// reply means this phone has no computer to give.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard message[credentialRequestKey] != nil else {
            replyHandler([:])
            return
        }
        replyHandler(reply?.payload ?? [:])
    }

    /// A request queued while the phone app was not running. Its delivery is
    /// what launched the app, in the background; the answer goes back as
    /// application context, since there is no one waiting on a reply.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard userInfo[credentialRequestKey] != nil else { return }
        Task { @MainActor in self.onRequest?() }
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        guard let credentials = HostCredentials(payload: context) else { return }
        Task { @MainActor in self.onCredentials?(credentials) }
    }

    #if os(iOS)
    // Required on iOS, where one watch can be swapped for another.
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}

// MARK: - Watch side

/// Where the watch gets the address and identity it dials the computer with.
///
/// The watch has no camera, so it can never scan a pairing code; the phone
/// scans once and hands the result over. After that the watch keeps its own
/// copy and needs the phone for nothing — the phone is asked only while the
/// watch has nothing, and the cursor never travels through it.
@MainActor
public final class CredentialSource: ObservableObject {
    public enum Phase: Equatable, Sendable {
        /// Credentials are in hand.
        case ready
        /// None stored; the phone has been asked and has not answered yet.
        case asking
        /// The phone could not be reached. It has to be opened by hand: iOS
        /// will not launch an app the user swiped out of the switcher, and no
        /// request from the watch overrides that.
        case phoneUnavailable
        /// The phone answered, and knows no computer.
        case phoneHasNone
    }

    @Published public private(set) var credentials: HostCredentials?
    @Published public private(set) var phase: Phase = .asking

    private let delegate = SessionDelegate()
    private let store = CredentialStore()
    private var giveUp: Task<Void, Never>?
    private var lastQueued = Date.distantPast

    /// How long a request may go unanswered before the watch says so. Long
    /// enough for a background launch of the phone app; short enough that the
    /// user is not left looking at "asking" for something that is not coming.
    private let patience: Duration = .seconds(6)

    public init() {}

    public func activate() {
        credentials = store.load()
        phase = credentials == nil ? .asking : .ready

        guard WCSession.isSupported() else {
            if credentials == nil { phase = .phoneUnavailable }
            return
        }

        delegate.onCredentials = { [weak self] in self?.adopt($0) }
        // The context the phone pushed while this app was not running waits
        // in the session, but only once the session is up: activation is
        // asynchronous, and reading it on the line after activate() reads
        // nothing. So it is read again here.
        delegate.onActivated = { [weak self] in
            self?.adoptStoredContext()
            self?.requestIfNeeded()
        }
        delegate.onReachability = { [weak self] reachable in
            // The phone app has just come up — opened by hand, most likely,
            // because the watch asked for exactly that.
            if reachable { self?.requestIfNeeded() }
        }

        let session = WCSession.default
        session.delegate = delegate
        session.activate()
        adoptStoredContext()
        requestIfNeeded()
    }

    /// Asks the phone, if there is nothing stored. Safe to call often.
    public func requestIfNeeded() {
        guard credentials == nil else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        phase = .asking

        if session.isReachable {
            // The phone app is running and can answer at once. The handlers
            // are spelled out as @Sendable because WatchConnectivity calls
            // them on its own queue: a closure written inside a main-actor
            // type and capturing it is otherwise inferred to be main-actor
            // too, and the runtime traps on entry when it is not.
            let replied: @Sendable ([String: Any]) -> Void = { [weak self] reply in
                let credentials = HostCredentials(payload: reply)
                Task { @MainActor in
                    if let credentials {
                        self?.adopt(credentials)
                    } else {
                        self?.giveUp?.cancel()
                        self?.phase = .phoneHasNone
                    }
                }
            }
            let failed: @Sendable (Error) -> Void = { _ in }
            session.sendMessage([credentialRequestKey: true], replyHandler: replied, errorHandler: failed)
        } else if Date().timeIntervalSince(lastQueued) > 5 {
            // Not running. A queued transfer is delivered by launching the
            // app in the background, which a message cannot do — unless the
            // user swiped it away, in which case nothing will, and the watch
            // has to say so. Older transfers are dropped first: undelivered
            // ones pile up, and a phone that comes back later would otherwise
            // be woken once for each.
            lastQueued = Date()
            for transfer in session.outstandingUserInfoTransfers
            where transfer.userInfo[credentialRequestKey] != nil {
                transfer.cancel()
            }
            session.transferUserInfo([credentialRequestKey: true])
        }

        giveUp?.cancel()
        giveUp = Task { [weak self] in
            guard let patience = self?.patience else { return }
            try? await Task.sleep(for: patience)
            guard let self, !Task.isCancelled, self.credentials == nil, self.phase == .asking else { return }
            self.phase = .phoneUnavailable
        }
    }

    /// Takes credentials from the phone — answering a request, or pushed
    /// because the phone has paired with a different computer since.
    private func adopt(_ new: HostCredentials) {
        giveUp?.cancel()
        giveUp = nil
        if new != credentials {
            credentials = new
            store.save(new)
        }
        phase = .ready
    }

    private func adoptStoredContext() {
        if let pushed = HostCredentials(payload: WCSession.default.receivedApplicationContext) {
            adopt(pushed)
        }
    }
}

// MARK: - Phone side

#if os(iOS)
/// The phone's end: hands the watch the computer it should dial, and answers
/// when the watch asks.
@MainActor
public final class CredentialPublisher {
    private let delegate = SessionDelegate()
    private var current: HostCredentials?

    public init() {}

    public func activate() {
        guard WCSession.isSupported() else { return }
        delegate.onActivated = { [weak self] in self?.push() }
        // Woken by a request the watch queued. Being launched was most of the
        // answer; the rest is to push what the watch asked for.
        delegate.onRequest = { [weak self] in self?.push() }

        let session = WCSession.default
        session.delegate = delegate
        session.activate()
    }

    /// The computer the watch should use, or nil if this phone knows none.
    public func publish(_ credentials: HostCredentials?) {
        delegate.reply = credentials
        guard credentials != current else { return }
        current = credentials
        push()
    }

    /// Application context: latest-wins, and kept by the system for a watch
    /// app that is not running. Never sent empty — a context replaces the
    /// previous one rather than merging, and the watch would take an empty
    /// one as nothing to say, not as an instruction to forget.
    private func push() {
        guard let current, WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        do {
            try session.updateApplicationContext(current.payload)
        } catch {
            print("watch context: \(error)")
        }
    }
}
#endif

#endif
