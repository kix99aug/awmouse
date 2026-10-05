import Foundation

/// What the watch asks the phone to do. The phone forwards it to the host;
/// the watch cannot reach the host itself, because the tunnel is a Go library
/// and Go has no watchOS port.
///
/// Shared between the two apps rather than declared on each side. The one
/// thing that has actually broken in this protocol before was a field name
/// drifting between two copies, and a copy on each side is how that happens.
public enum WatchEvent: Equatable, Sendable {
    /// Raw, unaccelerated pointer delta in points, with the interval that
    /// produced it in milliseconds — the same shape the phone's own surfaces
    /// produce, so the phone has nothing to convert.
    case move(dx: Double, dy: Double, dt: Double)
    case scroll(dx: Double, dy: Double)
    case click(WatchButton)
}

public enum WatchButton: String, Equatable, Sendable {
    case left = "l"
    case right = "r"
    case middle = "m"
}

// MARK: - Wire form

/// WatchConnectivity carries property lists, not Codable, so the event is
/// written as a small dictionary. The keys match the host's JSON protocol
/// deliberately: someone reading one will recognise the other.
extension WatchEvent {
    public var payload: [String: Any] {
        switch self {
        case .move(let dx, let dy, let dt):
            return ["t": "m", "dx": dx, "dy": dy, "dt": dt]
        case .scroll(let dx, let dy):
            return ["t": "s", "dx": dx, "dy": dy]
        case .click(let button):
            return ["t": "c", "b": button.rawValue]
        }
    }

    /// Returns nil for anything unrecognised. A newer watch talking to an
    /// older phone should lose the message it does not understand, not the
    /// connection.
    public init?(payload: [String: Any]) {
        switch payload["t"] as? String {
        case "m":
            guard let dx = payload["dx"] as? Double,
                  let dy = payload["dy"] as? Double,
                  let dt = payload["dt"] as? Double
            else { return nil }
            self = .move(dx: dx, dy: dy, dt: dt)

        case "s":
            guard let dx = payload["dx"] as? Double,
                  let dy = payload["dy"] as? Double
            else { return nil }
            self = .scroll(dx: dx, dy: dy)

        case "c":
            guard let raw = payload["b"] as? String,
                  let button = WatchButton(rawValue: raw)
            else { return nil }
            self = .click(button)

        default:
            return nil
        }
    }
}

/// The Handoff activity the watch advertises when the phone app is not
/// running.
///
/// iOS will not relaunch an app the user swiped away in the app switcher —
/// that gesture is read as "stop running this", and no background mechanism,
/// WatchConnectivity included, overrides it until the app is opened by hand.
/// Nothing in an app can change that. What Handoff can do is put the app one
/// tap away, on the lock screen and in the switcher, instead of leaving the
/// user to go and find it.
///
/// Shared so the two sides cannot disagree about the string; it is also
/// declared in both Info.plists, which is what makes the system carry it.
public let controlActivityType = "space.keybo.awmouse.control"
