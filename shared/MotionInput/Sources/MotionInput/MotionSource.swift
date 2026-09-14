#if os(iOS) || os(watchOS)

import CoreMotion
import Foundation

/// Drives a `PointerFilter` from the device's motion sensors.
///
/// Identical on iOS and watchOS — CoreMotion's API is the same on both — which
/// is the reason this lives in a shared package rather than in the app.
@MainActor
public final class MotionSource {
    /// Emits pointer deltas in points, with the elapsed interval in
    /// milliseconds, matching what the host expects on the wire.
    public var onDelta: ((Double, Double, Double) -> Void)?

    public var config: PointerFilter.Config {
        get { filter.config }
        set { filter.config = newValue }
    }

    public private(set) var isRunning = false

    private let manager = CMMotionManager()
    private var filter: PointerFilter
    private var lastTimestamp: TimeInterval?

    public init(config: PointerFilter.Config = .init()) {
        self.filter = PointerFilter(config: config)
    }

    public var isAvailable: Bool { manager.isDeviceMotionAvailable }

    public func start(updateInterval: TimeInterval = 1.0 / 60) {
        guard manager.isDeviceMotionAvailable, !isRunning else { return }

        manager.deviceMotionUpdateInterval = updateInterval
        lastTimestamp = nil
        filter.reset()
        isRunning = true

        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            MainActor.assumeIsolated {
                self.consume(motion)
            }
        }
    }

    public func stop() {
        guard isRunning else { return }
        manager.stopDeviceMotionUpdates()
        isRunning = false
        lastTimestamp = nil
    }

    /// Clears smoothing state without stopping the sensor — used when the
    /// pointer is re-engaged, so motion from before the clutch was pressed
    /// cannot leak into the first sample after it.
    public func reengage() {
        filter.reset()
        lastTimestamp = nil
    }

    private func consume(_ motion: CMDeviceMotion) {
        // Elapsed time comes from the sample timestamps rather than from
        // deviceMotionUpdateInterval, which is a request rather than a promise.
        defer { lastTimestamp = motion.timestamp }
        guard let previous = lastTimestamp else { return }

        let dt = motion.timestamp - previous
        guard dt > 0 else { return }

        // CMDeviceMotion.rotationRate is bias-corrected by CoreMotion's sensor
        // fusion. CMMotionManager.gyroData.rotationRate is the raw signal and
        // carries a bias that would walk the cursor across the screen while the
        // device sits still.
        //
        // Axes for a phone held upright in portrait, screen toward the user:
        // turning it left/right rotates about the device's Y axis, tilting it
        // up/down rotates about X. Both signs are empirical — flip them with
        // `invertX` / `invertY` rather than editing here.
        let (dx, dy) = filter.process(
            yaw: -motion.rotationRate.y,
            pitch: -motion.rotationRate.x,
            dt: dt
        )

        guard dx != 0 || dy != 0 else { return }
        onDelta?(dx, dy, dt * 1000)
    }
}

#endif
