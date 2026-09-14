import Foundation

/// Resolves device-frame rotation into world-referenced yaw and pitch.
///
/// Without this, the axis that means "aim left and right" depends on how the
/// device happens to be held. Upright, turning left rotates about the device's
/// Y axis; lying flat, that same Y axis is horizontal and rotating about it
/// rolls the device instead — a completely different gesture that also happens
/// to carry the opposite sign. Referencing gravity makes aiming mean the same
/// thing in any posture.
///
/// Pure arithmetic with no CoreMotion import, so the mapping can be tested
/// against known postures instead of by holding a phone at various angles.
public enum MotionGeometry {
    public struct Vector3: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var z: Double

        public init(x: Double, y: Double, z: Double) {
            self.x = x
            self.y = y
            self.z = z
        }
    }

    /// - Parameters:
    ///   - rotationRate: angular velocity in the device frame, rad/s.
    ///   - gravity: gravity in the device frame. CoreMotion reports this in g,
    ///     pointing down — flat and screen-up it reads (0, 0, -1).
    /// - Returns: rotation about world vertical, and about the horizontal axis
    ///   across the device, both in rad/s.
    public static func resolve(
        rotationRate w: Vector3,
        gravity g: Vector3
    ) -> (yaw: Double, pitch: Double) {
        let gLength = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        guard gLength > 1e-6 else { return (0, 0) }

        // World up, expressed in device coordinates.
        let up = Vector3(x: -g.x / gLength, y: -g.y / gLength, z: -g.z / gLength)

        // Yaw is the share of the rotation that acts about the vertical.
        let yaw = w.x * up.x + w.y * up.y + w.z * up.z

        // Pitch is measured about the device's X axis with its vertical
        // component removed, so that tilting up and down keeps meaning the same
        // thing even when the device is rolled.
        //
        // The device X axis is (1, 0, 0) by definition, so its projection onto
        // the horizontal plane simplifies to subtracting up.x * up.
        var right = Vector3(
            x: 1 - up.x * up.x,
            y: -up.x * up.y,
            z: -up.x * up.z
        )

        let rLength = (right.x * right.x + right.y * right.y + right.z * right.z).squareRoot()
        if rLength > 1e-3 {
            right = Vector3(x: right.x / rLength, y: right.y / rLength, z: right.z / rLength)
        } else {
            // The device's X axis is pointing straight up or down — held on its
            // edge — so there is no horizontal reference to project onto. Fall
            // back to the raw axis rather than dividing by nearly zero.
            right = Vector3(x: 1, y: 0, z: 0)
        }

        let pitch = w.x * right.x + w.y * right.y + w.z * right.z
        return (yaw, pitch)
    }
}
