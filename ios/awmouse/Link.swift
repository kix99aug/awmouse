import Foundation

// The Go tunnel, bound by gomobile into Frameworks/Awmtunnel.xcframework. It is
// an Objective-C module, so its types (AwmtunnelSession, AwmtunnelDial, …) are
// invisible to Swift without this import — a missing framework fails here with
// "no such module", which is the cue to run `make tunnel`.
import Awmtunnel

// gomobile classes are thin handles onto Go objects: each holds a reference
// number, and every call goes through the Go runtime, which does its own
// locking. That makes them safe to hand between isolation domains, which
// TunnelLink relies on — it dials on a detached task and sends on a serial
// queue, both off the main actor. Swift cannot see any of that through the
// Objective-C header, so it has to be declared.
extension AwmtunnelSession: @unchecked @retroactive Sendable {}

/// Where the host is: a tailcat address — the host's keys and relay,
/// base64url. Works from any network, and finds a direct path on the same one.
/// It is a secret: whoever holds it can drive the cursor.
struct Target: Equatable {
    let address: String

    /// The pairing code, if this target came with one. The QR carries the
    /// current code so a scanned phone is admitted without typing; a pasted
    /// address has none, and the host will ask for it.
    var code: String?

    /// Parses what a user might paste: a bare `tc…` address.
    init?(parsing text: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("tc"), !s.contains("/") else { return nil }
        address = s
    }

    /// Parses the `awmouse://pair?tc=…&code=…` deep link the host renders as
    /// a QR code.
    init?(pairingLink url: URL) {
        guard url.scheme == "awmouse",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let tc = items.first(where: { $0.name == "tc" })?.value
        else { return nil }
        address = tc
        code = items.first(where: { $0.name == "code" })?.value
    }

    var text: String { address }
}

/// The host declining to admit this phone. Distinct from a transport failure:
/// the connection worked, and the host said no.
enum PairingError: LocalizedError, Equatable {
    /// Not paired, and no code or the wrong one. Ask the user for the code
    /// shown on the host and try again.
    case codeRequired
    /// Too many wrong codes; the host is refusing for a moment.
    case locked
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .codeRequired: return "Enter the pairing code shown on your computer."
        case .locked: return "Too many wrong codes — wait a moment and try again."
        case .refused(let why): return "The computer refused the connection (\(why))."
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

    /// Dials the host and asks to be admitted. Bootstrapping goes through the
    /// relay before a direct path is found, so this can take a few seconds the
    /// first time. `onClosed` fires if the tunnel ends underneath us.
    ///
    /// Throws `PairingError` when the host answers but declines — a phone it
    /// has not seen must present the code from its window — and other errors
    /// when there was no answer at all.
    static func dial(address: String, code: String?, deviceName: String,
                     onClosed: @escaping @MainActor (String) -> Void) async throws -> TunnelLink {
        let listener = ClosedListener(onClosed)
        let key = ClientIdentity.key
        let session: AwmtunnelSession? = try await Task.detached {
            // Dial is a top-level Go function, which gomobile exposes as a C
            // function rather than an Objective-C method. Swift turns a
            // trailing NSError** into `throws` only for methods, so here the
            // error comes back through an explicit out-parameter. The Session
            // methods below are methods, and do get the `throws` form.
            var error: NSError?
            let session = AwmtunnelDial(address, key, 15_000, listener, &error)
            if let error { throw error }
            return session
        }.value
        guard let session else { throw TunnelError.noSession }

        // A known phone is admitted whatever it sends, so an empty code is
        // the right thing to send when there is none: it costs nothing when
        // paired, and elicits the "code required" answer when not.
        // Read the verdict out inside the task: the result object is a Go
        // handle Swift cannot see is Sendable, and two plain values are.
        let (admitted, reason): (Bool, String) = try await Task.detached {
            let r = try session.hello(code ?? "", name: deviceName, timeoutMillis: 5_000)
            return (r.admitted, r.reason)
        }.value
        if !admitted {
            _ = try? session.close()
            switch reason {
            case AwmtunnelReasonCode: throw PairingError.codeRequired
            case AwmtunnelReasonLocked: throw PairingError.locked
            default: throw PairingError.refused(reason)
            }
        }
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
