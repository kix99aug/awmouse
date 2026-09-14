import Testing

@testable import MotionInput

/// The defining failure of an air mouse: the cursor wanders while the device is
/// held still. Nothing in the pipeline may manufacture motion from stillness.
@Test func stillnessProducesNoDrift() {
    var filter = PointerFilter()

    var totalX = 0.0
    var totalY = 0.0
    for _ in 0..<600 {
        let (dx, dy) = filter.process(yaw: 0, pitch: 0, dt: 1.0 / 60)
        totalX += dx
        totalY += dy
    }

    #expect(totalX == 0)
    #expect(totalY == 0)
}

/// Residual sensor noise below the deadzone must not reach the cursor, even
/// when it persists for a long time.
@Test func tremorBelowDeadzoneIsRejected() {
    let config = PointerFilter.Config(deadzone: 0.05)
    var filter = PointerFilter(config: config)

    var total = 0.0
    for i in 0..<600 {
        // Alternating small nudges, well inside the deadzone.
        let noise = (i % 2 == 0) ? 0.02 : -0.02
        let (dx, _) = filter.process(yaw: noise, pitch: 0, dt: 1.0 / 60)
        total += dx
    }

    #expect(total == 0)
}

/// A hard threshold would make the cursor leap the instant it is crossed,
/// because output jumps from zero straight to the full threshold value.
/// Subtracting the deadzone instead keeps the response continuous.
@Test func deadzoneIsContinuousAtItsThreshold() {
    let config = PointerFilter.Config(smoothing: 1, deadzone: 0.1, sensitivity: 1000)

    var justBelow = PointerFilter(config: config)
    var justAbove = PointerFilter(config: config)

    let (below, _) = justBelow.process(yaw: 0.0999, pitch: 0, dt: 1.0 / 60)
    let (above, _) = justAbove.process(yaw: 0.1001, pitch: 0, dt: 1.0 / 60)

    #expect(below == 0)
    #expect(above > 0)
    // The step across the boundary must be negligible, not the whole deadzone.
    #expect(above < 0.01)
}

/// Scaling by angle rather than by raw rate is what keeps the feel identical
/// when the sensor delivers samples at a different rate.
@Test func travelIsIndependentOfSampleRate() {
    let config = PointerFilter.Config(smoothing: 1, deadzone: 0, sensitivity: 1000)

    func travel(samples: Int, dt: Double) -> Double {
        var filter = PointerFilter(config: config)
        var total = 0.0
        for _ in 0..<samples {
            total += filter.process(yaw: 0.5, pitch: 0, dt: dt).dx
        }
        return total
    }

    // One second of identical rotation, sampled at 60 Hz and at 120 Hz.
    let slow = travel(samples: 60, dt: 1.0 / 60)
    let fast = travel(samples: 120, dt: 1.0 / 120)

    #expect(abs(slow - fast) < 1e-9)
}

@Test func invertFlipsEachAxisIndependently() {
    let config = PointerFilter.Config(
        smoothing: 1, deadzone: 0, sensitivity: 1000, invertX: true, invertY: false
    )
    var filter = PointerFilter(config: config)

    let (dx, dy) = filter.process(yaw: 0.5, pitch: 0.5, dt: 1.0 / 60)

    #expect(dx < 0)
    #expect(dy > 0)
}

/// Re-engaging the clutch must not let pre-clutch motion leak through as a
/// first-sample jump.
@Test func resetClearsSmoothingState() {
    let config = PointerFilter.Config(smoothing: 0.2, deadzone: 0, sensitivity: 1000)
    var filter = PointerFilter(config: config)

    // Build up smoothing state with sustained rotation.
    for _ in 0..<50 {
        _ = filter.process(yaw: 1.0, pitch: 0, dt: 1.0 / 60)
    }
    filter.reset()

    // With state cleared, a zero sample must produce exactly nothing.
    let (dx, dy) = filter.process(yaw: 0, pitch: 0, dt: 1.0 / 60)
    #expect(dx == 0)
    #expect(dy == 0)
}

/// Smoothing trades responsiveness for steadiness; the extremes should behave
/// as their names suggest.
@Test func smoothingControlsResponsiveness() {
    func firstSample(smoothing: Double) -> Double {
        var filter = PointerFilter(
            config: .init(smoothing: smoothing, deadzone: 0, sensitivity: 1000)
        )
        return filter.process(yaw: 1.0, pitch: 0, dt: 1.0 / 60).dx
    }

    let responsive = firstSample(smoothing: 1.0)
    let smooth = firstSample(smoothing: 0.1)

    #expect(responsive > smooth)
    #expect(smooth > 0)
}
