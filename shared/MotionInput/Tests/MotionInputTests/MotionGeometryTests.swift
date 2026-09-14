import Testing

@testable import MotionInput

private typealias V = MotionGeometry.Vector3

/// Gravity as CoreMotion reports it for a phone lying flat on a desk, screen up:
/// the device's Z axis points at the ceiling, so gravity reads -1 along it.
private let flat = V(x: 0, y: 0, z: -1)

/// Held upright in portrait, screen toward the user: the device's Y axis points
/// at the ceiling.
private let upright = V(x: 0, y: -1, z: 0)

/// The bug this mapping exists to fix. Held flat, aiming left and right is
/// rotation about the device's Z axis; held upright it is rotation about Y.
/// Reading a fixed axis gets one posture right and silently does something else
/// entirely in the other.
@Test func yawFollowsWorldVerticalRegardlessOfPosture() {
    let spinningFlat = MotionGeometry.resolve(
        rotationRate: V(x: 0, y: 0, z: 1), gravity: flat
    )
    #expect(abs(spinningFlat.yaw - 1) < 1e-9)

    let turningUpright = MotionGeometry.resolve(
        rotationRate: V(x: 0, y: 1, z: 0), gravity: upright
    )
    #expect(abs(turningUpright.yaw - 1) < 1e-9)
}

/// Rolling a flat device — the gesture that was previously being read as aim —
/// must now register as neither yaw nor pitch.
@Test func rollingAFlatDeviceDoesNotAim() {
    let rolled = MotionGeometry.resolve(
        rotationRate: V(x: 0, y: 1, z: 0), gravity: flat
    )
    #expect(abs(rolled.yaw) < 1e-9)
    #expect(abs(rolled.pitch) < 1e-9)
}

@Test func pitchIsAboutTheAcrossDeviceAxisInEitherPosture() {
    let tiltedFlat = MotionGeometry.resolve(
        rotationRate: V(x: 1, y: 0, z: 0), gravity: flat
    )
    #expect(abs(tiltedFlat.pitch - 1) < 1e-9)

    let tiltedUpright = MotionGeometry.resolve(
        rotationRate: V(x: 1, y: 0, z: 0), gravity: upright
    )
    #expect(abs(tiltedUpright.pitch - 1) < 1e-9)
}

/// Yaw and pitch must stay separable, or aiming sideways would drag the cursor
/// diagonally.
@Test func yawAndPitchDoNotBleedIntoEachOther() {
    let pureYaw = MotionGeometry.resolve(
        rotationRate: V(x: 0, y: 0, z: 1), gravity: flat
    )
    #expect(abs(pureYaw.pitch) < 1e-9)

    let purePitch = MotionGeometry.resolve(
        rotationRate: V(x: 1, y: 0, z: 0), gravity: flat
    )
    #expect(abs(purePitch.yaw) < 1e-9)
}

/// A device tilted halfway between flat and upright is the normal way to hold
/// an air mouse, and must aim as well as either extreme.
@Test func aimingWorksAtIntermediateAngles() {
    let s = (0.5).squareRoot()
    let tilted = V(x: 0, y: -s, z: -s)

    // Rotation about world vertical, expressed in this tilted device's frame.
    let aroundVertical = V(x: 0, y: s, z: s)

    let result = MotionGeometry.resolve(rotationRate: aroundVertical, gravity: tilted)
    #expect(abs(result.yaw - 1) < 1e-9)
    #expect(abs(result.pitch) < 1e-9)
}

/// Held on its edge the device has no horizontal X axis to project onto; the
/// fallback must return finite numbers rather than dividing by nearly zero.
@Test func edgeOnPostureDoesNotProduceNaN() {
    let onEdge = V(x: -1, y: 0, z: 0)

    let result = MotionGeometry.resolve(
        rotationRate: V(x: 0.3, y: 0.4, z: 0.5), gravity: onEdge
    )
    #expect(result.yaw.isFinite)
    #expect(result.pitch.isFinite)
}

/// A missing or zeroed gravity reading must produce stillness, not garbage.
@Test func absentGravityProducesNoMotion() {
    let result = MotionGeometry.resolve(
        rotationRate: V(x: 1, y: 1, z: 1), gravity: V(x: 0, y: 0, z: 0)
    )
    #expect(result.yaw == 0)
    #expect(result.pitch == 0)
}

/// CoreMotion reports gravity in g rather than as a unit vector, and the reading
/// dips below 1 g under acceleration. Scale must not change the result.
@Test func gravityMagnitudeDoesNotAffectResult() {
    let weak = MotionGeometry.resolve(
        rotationRate: V(x: 0, y: 0, z: 1), gravity: V(x: 0, y: 0, z: -0.7)
    )
    #expect(abs(weak.yaw - 1) < 1e-9)
}
