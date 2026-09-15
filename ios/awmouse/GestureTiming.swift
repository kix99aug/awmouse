import Foundation

enum GestureTiming {
    /// Separates a tap from a hold.
    ///
    /// Shared deliberately. In Air Mouse mode this same value is how long
    /// aiming waits before the cursor starts moving, which makes the two
    /// outcomes exactly complementary: release before it and you get a click
    /// with the cursor still where you aimed, hold past it and you get motion
    /// with no click. Were the two allowed to drift apart, the shorter one
    /// would open a window in which the cursor has already moved and releasing
    /// *still* counts as a tap.
    static let tapMaxDuration: TimeInterval = 0.25

    /// A tap followed by a press this soon becomes a drag.
    static let dragArmWindow: TimeInterval = 0.3
}
