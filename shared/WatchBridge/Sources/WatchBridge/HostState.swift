import Foundation

/// What the phone tells the watch about the far end. Without it the watch
/// cannot tell "aiming, and the cursor is moving" from "aiming into a void",
/// and the two look identical on the wrist.
public struct HostState: Equatable, Sendable {
    public var connected: Bool
    public var name: String

    public init(connected: Bool = false, name: String = "") {
        self.connected = connected
        self.name = name
    }

    public var payload: [String: Any] { ["connected": connected, "name": name] }

    public init?(payload: [String: Any]) {
        guard let connected = payload["connected"] as? Bool else { return nil }
        self.connected = connected
        self.name = payload["name"] as? String ?? ""
    }
}
