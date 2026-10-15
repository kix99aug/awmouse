import Foundation

/// A computer the phone has paired with.
public struct KnownComputer: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// The tailcat address from the QR code. Holding it is enough to connect,
    /// which is why the host treats it as a secret.
    public var address: String
    /// What the computer calls itself. Empty for one that never said.
    public var name: String

    public var id: String { address }

    public init(address: String, name: String) {
        self.address = address
        self.name = name
    }
}

/// What the watch needs to reach the phone's computers without the phone.
///
/// The watch has no camera, so it can never scan a pairing code; the phone
/// scans and hands the results over. That makes this the one thing on the
/// watch worth protecting.
///
/// The phone pushes them as application context, which is latest-wins and is
/// kept by the system for the watch's next launch, and answers with them when
/// the watch asks. The watch keeps its own copy in the Keychain, which is what
/// lets it dial with the phone switched off.
public struct HostCredentials: Codable, Equatable, Sendable {
    /// This client's identity, so the hosts recognise the watch as a device
    /// they have already admitted rather than a stranger. One key for every
    /// computer, as on the phone.
    public var key: String
    /// Most recently used first — the phone's own order, so the watch's
    /// default is the computer the phone would pick.
    public var computers: [KnownComputer]

    public init(key: String, computers: [KnownComputer]) {
        self.key = key
        self.computers = computers
    }

    /// The WatchConnectivity form. Prefixed, so that a context or reply from
    /// some other version cannot be mistaken for these by accident. Nested
    /// dictionaries rather than encoded JSON, because WatchConnectivity carries
    /// property lists and these are one.
    public var payload: [String: Any] {
        ["c.key": key, "c.list": computers.map { ["a": $0.address, "n": $0.name] }]
    }

    /// Nil for anything without a key and at least one computer: an empty
    /// reply is the phone saying it knows none, and must not look usable.
    public init?(payload: [String: Any]) {
        guard let key = payload["c.key"] as? String, !key.isEmpty,
              let list = payload["c.list"] as? [[String: Any]]
        else { return nil }
        let computers = list.compactMap { entry -> KnownComputer? in
            guard let address = entry["a"] as? String, !address.isEmpty else { return nil }
            return KnownComputer(address: address, name: entry["n"] as? String ?? "")
        }
        guard !computers.isEmpty else { return nil }
        self.key = key
        self.computers = computers
    }
}
