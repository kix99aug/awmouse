import Foundation

/// A computer this phone has paired with. The address is the credential and
/// never changes; the name is what the host called itself on the last
/// successful connection, so it can be shown instead of a wall of base64.
struct KnownHost: Codable, Identifiable, Equatable {
    var address: String
    var name: String
    var lastUsed: Date

    var id: String { address }
}

/// The computers this phone knows, most recently used first.
///
/// Kept in UserDefaults rather than the Keychain: a tailcat address lets its
/// holder drive that computer's cursor, but only after the host has admitted
/// this phone, and the host can revoke it. The pairing code — the part that
/// would let a stranger in — is single-use and is never stored.
struct KnownHosts {
    private static let key = "knownHosts"

    private(set) var all: [KnownHost]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([KnownHost].self, from: data) {
            all = decoded
        } else if let legacy = defaults.string(forKey: "lastURL"), !legacy.isEmpty {
            // Before this phone could know more than one computer it stored a
            // bare address. Carry it across rather than making the user pair
            // again; the name fills in on the next connection.
            all = [KnownHost(address: legacy, name: "Computer", lastUsed: .now)]
            defaults.removeObject(forKey: "lastURL")
        } else {
            all = []
        }
        sort()
    }

    private let defaults: UserDefaults

    /// The one to reconnect to without being asked.
    var mostRecent: KnownHost? { all.first }

    /// Records a successful connection: adds the computer, or updates the
    /// name and moves it to the front.
    mutating func record(address: String, name: String) {
        var host = all.first { $0.address == address }
            ?? KnownHost(address: address, name: name, lastUsed: .now)
        host.lastUsed = .now
        // An empty name means an older host that does not send one; keep
        // whatever was there rather than blanking a good label.
        if !name.isEmpty { host.name = name }

        all.removeAll { $0.address == address }
        all.insert(host, at: 0)
        save()
    }

    mutating func forget(_ host: KnownHost) {
        all.removeAll { $0.address == host.address }
        save()
    }

    private mutating func sort() {
        all.sort { $0.lastUsed > $1.lastUsed }
    }

    private mutating func save() {
        sort()
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
