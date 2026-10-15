import Foundation

/// What the watch asks the phone to do. The phone forwards it to the
/// computer: the watch cannot reach the computer itself, because watchOS
/// keeps raw sockets from third-party apps, and the tunnel is made of them.
/// See DESIGN.md, "Why the watch goes through the phone".
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
    /// A button held down or let go, for a drag. Separate from `click`
    /// because the two halves are far apart in time and the cursor moves
    /// between them.
    case button(WatchButton, down: Bool)
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
        case .button(let button, let down):
            return ["t": "b", "b": button.rawValue, "d": down]
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

        case "b":
            guard let raw = payload["b"] as? String,
                  let button = WatchButton(rawValue: raw),
                  let down = payload["d"] as? Bool
            else { return nil }
            self = .button(button, down: down)

        default:
            return nil
        }
    }
}

/// The Handoff activity the watch advertises while it cannot reach the phone
/// app.
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
