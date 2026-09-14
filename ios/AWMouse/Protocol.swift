import Foundation

/// Wire format shared with the Go host. Deltas are relative and unaccelerated:
/// the host owns the acceleration curve and absolute positioning, so this app
/// never needs to know the screen geometry it is driving.
struct Msg: Encodable {
    let t: String

    var dx: Double?
    var dy: Double?
    var dt: Double?   // milliseconds

    var b: String?
    var d: Bool?

    static func move(dx: Double, dy: Double, dt: Double) -> Msg {
        Msg(t: "m", dx: dx, dy: dy, dt: dt)
    }

    static func scroll(dx: Double, dy: Double) -> Msg {
        Msg(t: "s", dx: dx, dy: dy)
    }

    static func button(_ button: MouseButton, down: Bool) -> Msg {
        Msg(t: "c", b: button.rawValue, d: down)
    }
}

enum MouseButton: String {
    case left = "l"
    case right = "r"
    case middle = "m"
}
