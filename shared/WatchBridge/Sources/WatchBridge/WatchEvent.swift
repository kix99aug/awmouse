import Foundation

/// What the watch asks the computer to do.
///
/// The watch speaks to the host directly, over its own tunnel, so these are
/// written in the host's protocol rather than in anything of the phone's. They
/// live here rather than in the watch target so that the encoding can be
/// tested on a machine that is not a watch.
public enum WatchEvent: Equatable, Sendable {
    /// Raw, unaccelerated pointer delta in points, with the interval that
    /// produced it in milliseconds — the same shape the phone's own surfaces
    /// produce. The host owns the acceleration curve.
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

extension WatchEvent {
    /// The JSON lines the host reads — host/internal/proto. Built by hand
    /// rather than through JSONEncoder because the phone's message type lives
    /// in the phone target, and four fixed shapes do not justify a second copy
    /// of it.
    ///
    /// A click is two messages, not one. The host counts clicks itself — that
    /// is how it tells a double click from two single ones — so it wants the
    /// press and the release.
    public var messages: [String] {
        switch self {
        case .move(let dx, let dy, let dt):
            return [#"{"t":"m","dx":\#(dx),"dy":\#(dy),"dt":\#(dt)}"#]
        case .scroll(let dx, let dy):
            return [#"{"t":"s","dx":\#(dx),"dy":\#(dy)}"#]
        case .click(let button):
            return Self.button(button, down: true) + Self.button(button, down: false)
        case .button(let button, let down):
            return Self.button(button, down: down)
        }
    }

    /// The host reads a missing "d" as false, so a release carries no flag at
    /// all — the same shape the phone's encoder produces.
    private static func button(_ button: WatchButton, down: Bool) -> [String] {
        down
            ? [#"{"t":"c","b":"\#(button.rawValue)","d":true}"#]
            : [#"{"t":"c","b":"\#(button.rawValue)"}"#]
    }

    /// Two moves in a row can be sent as one: motion is a quantity, and ten
    /// small moves and their sum land the cursor in the same place. Anything
    /// else is a discrete intention and is never merged.
    public func merged(with next: WatchEvent) -> WatchEvent? {
        switch (self, next) {
        case let (.move(ax, ay, at), .move(bx, by, bt)):
            return .move(dx: ax + bx, dy: ay + by, dt: at + bt)
        case let (.scroll(ax, ay), .scroll(bx, by)):
            return .scroll(dx: ax + bx, dy: ay + by)
        default:
            return nil
        }
    }
}

/// The Handoff activity the watch advertises while it has no address for the
/// computer and needs the phone app opened to get one.
///
/// iOS will not relaunch an app the user swiped away in the app switcher, and
/// nothing in an app can change that. What Handoff can do is put the app one
/// tap away, on the lock screen and in the switcher, instead of leaving the
/// user to go and find it.
///
/// Shared so the two sides cannot disagree about the string; it is also
/// declared in both Info.plists, which is what makes the system carry it.
public let controlActivityType = "space.keybo.awmouse.control"
