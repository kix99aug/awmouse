import Foundation

/// A computer the phone has paired with.
public struct KnownComputer: Equatable, Sendable, Identifiable {
    /// Identifies the computer between the two apps. It is the tailcat
    /// address, because that is what the phone keys its list on; the watch
    /// never dials it.
    public var id: String
    /// What the computer calls itself. Empty for one that never said.
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// What the phone tells the watch: what it is doing about the computer, and
/// which computers it could be doing it with.
///
/// Without it the watch could not tell "the cursor is moving" from "sending
/// into a void", and the two look identical on the wrist.
public struct PhoneStatus: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case connected
        case connecting
        /// Not connected and not trying. `note` says why, when there is a why.
        case idle
    }

    public var phase: Phase
    /// The computer the phone is connected to or trying, if any.
    public var current: KnownComputer?
    /// Every computer the phone knows, most recently used first.
    public var computers: [KnownComputer]
    /// A few words on why the phone is idle: a failure, or a pairing that
    /// needs scanning again.
    public var note: String?

    public init(phase: Phase = .idle, current: KnownComputer? = nil,
                computers: [KnownComputer] = [], note: String? = nil) {
        self.phase = phase
        self.current = current
        self.computers = computers
        self.note = note
    }

    /// WatchConnectivity carries property lists, so this is nested
    /// dictionaries rather than encoded JSON.
    public var payload: [String: Any] {
        var p: [String: Any] = [
            "p": phase.rawValue,
            "list": computers.map { ["id": $0.id, "n": $0.name] },
        ]
        if let current { p["cur"] = ["id": current.id, "n": current.name] }
        if let note { p["note"] = note }
        return p
    }

    public init?(payload: [String: Any]) {
        guard let raw = payload["p"] as? String, let phase = Phase(rawValue: raw) else { return nil }
        func computer(_ any: Any?) -> KnownComputer? {
            guard let d = any as? [String: Any], let id = d["id"] as? String, !id.isEmpty else { return nil }
            return KnownComputer(id: id, name: d["n"] as? String ?? "")
        }
        self.phase = phase
        self.current = computer(payload["cur"])
        self.computers = (payload["list"] as? [Any] ?? []).compactMap(computer)
        self.note = payload["note"] as? String
    }
}
