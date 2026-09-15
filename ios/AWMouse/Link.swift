import Foundation

/// Where the host is. The QR code encodes one of these as a deep link; the
/// text field accepts either form.
enum Target: Equatable {
    /// The POC transport: a plain WebSocket on the local network.
    case webSocket(URL)
    /// A tailcat address — the host's keys and relay, base64url. Works from
    /// any network, and is a secret: whoever holds it can drive the cursor.
    case tunnel(String)

    /// Parses what a user might paste: a `ws://` URL, or a bare `tc…` address.
    init?(parsing text: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("tc"), !s.contains("/") {
            self = .tunnel(s)
        } else if let url = URL(string: s), url.scheme == "ws" || url.scheme == "wss" {
            self = .webSocket(url)
        } else {
            return nil
        }
    }

    /// Parses the `awmouse://pair?…` deep link the host renders as a QR code.
    init?(pairingLink url: URL) {
        guard url.scheme == "awmouse",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        if let tc = items.first(where: { $0.name == "tc" })?.value {
            self = .tunnel(tc)
        } else if let ws = items.first(where: { $0.name == "ws" })?.value, let u = URL(string: ws) {
            self = .webSocket(u)
        } else {
            return nil
        }
    }

    var text: String {
        switch self {
        case .webSocket(let url): return url.absoluteString
        case .tunnel(let addr): return addr
        }
    }
}

/// One open connection to the host. `Client` owns exactly one and speaks JSON
/// through it; the link is only bytes and lifecycle.
@MainActor
protocol Link: AnyObject {
    /// Sends one JSON-encoded message. `done` runs on the main actor once the
    /// message has been handed off or has failed — it gates the client's
    /// motion coalescing, so it must always be called.
    func send(_ json: String, done: @escaping @MainActor (Error?) -> Void)
    func close()
}

// MARK: - WebSocket

/// The POC link, unchanged from before the tunnel existed.
@MainActor
final class WebSocketLink: Link {
    private let task: URLSessionWebSocketTask
    private let onFailure: @MainActor (Error) -> Void

    /// Opens the socket. `onOpen` fires once the host has answered a ping —
    /// a WebSocket task otherwise reports failure only on first I/O.
    init(url: URL,
         onOpen: @escaping @MainActor () -> Void,
         onFailure: @escaping @MainActor (Error) -> Void) {
        self.onFailure = onFailure
        task = URLSession.shared.webSocketTask(with: url)
        task.resume()

        task.sendPing { error in
            Task { @MainActor in
                if let error { onFailure(error) } else { onOpen() }
            }
        }
        receiveLoop()
    }

    /// The host sends nothing, but the receive loop is what surfaces a dropped
    /// or refused connection.
    private func receiveLoop() {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success: self.receiveLoop()
                case .failure(let error): self.onFailure(error)
                }
            }
        }
    }

    func send(_ json: String, done: @escaping @MainActor (Error?) -> Void) {
        task.send(.string(json)) { error in
            Task { @MainActor in done(error) }
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

// MARK: - Tunnel

/// The tailcat link, through the Go framework bound from
/// `host/mobile/awmtunnel`. Every call into Go is made off the main actor:
/// dialing blocks for the relay handshake, and sends block briefly while the
/// in-process TCP stack takes the bytes.
final class TunnelLink: NSObject, Link, @unchecked Sendable {
    private let session: AwmtunnelSession
    private let queue = DispatchQueue(label: "awmouse.tunnel")

    private init(session: AwmtunnelSession) {
        self.session = session
    }

    /// Dials the host. Bootstrapping goes through the relay before a direct
    /// path is found, so this can take a few seconds the first time.
    /// `onClosed` fires if the tunnel ends underneath us.
    static func dial(address: String,
                     onClosed: @escaping @MainActor (String) -> Void) async throws -> TunnelLink {
        let listener = ClosedListener(onClosed)
        let key = ClientIdentity.key
        let session: AwmtunnelSession? = try await Task.detached {
            try AwmtunnelDial(address, key, 15_000, listener)
        }.value
        guard let session else { throw TunnelError.noSession }
        return TunnelLink(session: session)
    }

    func send(_ json: String, done: @escaping @MainActor (Error?) -> Void) {
        queue.async { [session] in
            var failure: Error?
            do { try session.send(json) } catch { failure = error }
            Task { @MainActor in done(failure) }
        }
    }

    /// Round trip to the host in milliseconds. Also the liveness check: a
    /// crashed host sends no FIN, and a write into the tunnel succeeds
    /// locally whether or not anyone is listening.
    func ping() async throws -> Int64 {
        let session = self.session
        return try await Task.detached {
            var ms: Int64 = 0
            try session.ping(3_000, ret0_: &ms)
            return ms
        }.value
    }

    func close() {
        queue.async { [session] in _ = try? session.close() }
    }

    /// Receives Go's one callback, on a Go goroutine, and hops to the main
    /// actor.
    private final class ClosedListener: NSObject, AwmtunnelListenerProtocol, @unchecked Sendable {
        private let handler: @MainActor (String) -> Void
        init(_ handler: @escaping @MainActor (String) -> Void) { self.handler = handler }
        func onClosed(_ reason: String?) {
            let handler = self.handler
            Task { @MainActor in handler(reason ?? "closed") }
        }
    }

    enum TunnelError: LocalizedError {
        case noSession
        var errorDescription: String? { "tunnel did not open" }
    }
}

/// The phone's tailcat identity, generated once and kept in the Keychain so
/// the host can recognise the same phone across sessions.
enum ClientIdentity {
    private static let service = "space.keybo.awmouse.tunnel"
    private static let account = "client-key"

    static var key: String {
        if let existing = read() { return existing }
        let fresh = AwmtunnelNewKey()
        write(fresh)
        return fresh
    }

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String) {
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(attrs as CFDictionary, nil)
    }
}
