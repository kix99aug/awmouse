import Foundation

/// Turns angular velocity into pointer deltas.
///
/// Deliberately free of any CoreMotion import: this is the part that decides
/// how an air mouse *feels*, and keeping it pure means it can be unit tested
/// rather than only evaluated by waving a phone around.
public struct PointerFilter: Sendable {
    public struct Config: Sendable {
        /// EMA weight for each new sample, 0...1. Higher is more responsive and
        /// more jittery; lower is smoother and laggier.
        public var smoothing: Double

        /// Angular rate, in rad/s, below which motion is treated as tremor.
        public var deadzone: Double

        /// Points of cursor travel per radian of rotation. Scaling by angle
        /// rather than by raw rate is what makes the feel independent of sample
        /// rate.
        public var sensitivity: Double

        public var invertX: Bool
        public var invertY: Bool

        public init(
            smoothing: Double = 0.35,
            deadzone: Double = 0.012,
            sensitivity: Double = 3000,
            invertX: Bool = false,
            invertY: Bool = false
        ) {
            self.smoothing = smoothing
            self.deadzone = deadzone
            self.sensitivity = sensitivity
            self.invertX = invertX
            self.invertY = invertY
        }
    }

    public var config: Config

    private var smoothedYaw = 0.0
    private var smoothedPitch = 0.0

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Consumes one motion sample and returns the pointer delta it implies.
    ///
    /// - Parameters:
    ///   - yaw: rotation rate about the device's vertical axis, rad/s.
    ///   - pitch: rotation rate about the device's horizontal axis, rad/s.
    ///   - dt: seconds since the previous sample.
    public mutating func process(yaw: Double, pitch: Double, dt: Double) -> (dx: Double, dy: Double) {
        guard dt > 0 else { return (0, 0) }

        // Smooth before gating. Averaging the noise down first means the
        // deadzone only has to reject what survives, rather than having to be
        // wide enough to swallow raw sensor jitter.
        let a = config.smoothing
        smoothedYaw = a * yaw + (1 - a) * smoothedYaw
        smoothedPitch = a * pitch + (1 - a) * smoothedPitch

        let gatedYaw = Self.deadzone(smoothedYaw, config.deadzone)
        let gatedPitch = Self.deadzone(smoothedPitch, config.deadzone)

        // Rate × time = angle, so the result is points per radian turned and
        // does not change when the sensor's update rate does.
        var dx = gatedYaw * dt * config.sensitivity
        var dy = gatedPitch * dt * config.sensitivity

        if config.invertX { dx = -dx }
        if config.invertY { dy = -dy }

        return (dx, dy)
    }

    /// Resets the smoothing state. Call when the pointer is re-engaged, so that
    /// motion from before the clutch was pressed cannot leak into the first
    /// sample after it.
    public mutating func reset() {
        smoothedYaw = 0
        smoothedPitch = 0
    }

    /// Subtractive rather than hard-cut: a hard threshold makes the cursor jump
    /// the moment it is crossed, because output leaps from zero to the full
    /// threshold value. Subtracting instead keeps the response continuous.
    private static func deadzone(_ v: Double, _ width: Double) -> Double {
        let magnitude = abs(v) - width
        guard magnitude > 0 else { return 0 }
        return magnitude * (v < 0 ? -1 : 1)
    }
}
