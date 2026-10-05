import Foundation

/// What the watch needs to reach a computer without the phone.
///
/// The watch has no camera, so it can never scan a pairing code; the phone
/// scans once and hands the result over. That makes this the one thing on the
/// watch worth protecting — the address alone is enough to connect, which is
/// why the host treats it as a secret.
///
/// Sent as application context, which is latest-wins and, unlike a message,
/// is kept by the system and handed to the watch app the next time it starts.
/// That is what lets the watch dial a computer with the phone switched off.
public struct HostCredentials: Equatable, Sendable {
    /// The tailcat address from the QR code.
    public var address: String
    /// This client's own identity, so the host recognises the watch as a
    /// device it has already admitted rather than a stranger.
    public var key: String
    /// What the computer calls itself, for the status line.
    public var name: String

    public init(address: String, key: String, name: String) {
        self.address = address
        self.key = key
        self.name = name
    }

    /// Prefixed keys, because this shares the context dictionary with
    /// HostState and the two are written by different code paths.
    public var payload: [String: Any] {
        ["c.addr": address, "c.key": key, "c.name": name]
    }

    public init?(payload: [String: Any]) {
        guard let address = payload["c.addr"] as? String, !address.isEmpty,
              let key = payload["c.key"] as? String
        else { return nil }
        self.address = address
        self.key = key
        self.name = payload["c.name"] as? String ?? ""
    }
}
