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

    /// Created on first use rather than on init. Constructing a
    /// `CMMotionManager` opens a connection to the motion daemon, and this type
    /// is typically built while the app is starting up — which puts that work
    /// on the path to the first frame even when the user never selects a
    /// motion-driven mode.
    private lazy var manager = CMMotionManager()

    private var filter: PointerFilter
    private var lastTimestamp: TimeInterval?

    /// Serial, so samples arrive in order, and off the main thread so that
    /// sensor delivery is not competing with drawing.
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "MotionInput.samples"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()

    public init(config: PointerFilter.Config = .init()) {
        self.filter = PointerFilter(config: config)
    }

    /// Touching this builds the underlying manager, so ask only once the user
    /// has actually chosen a motion-driven mode.
    public var isAvailable: Bool { manager.isDeviceMotionAvailable }

    public func start(updateInterval: TimeInterval = 1.0 / 60) {
        guard manager.isDeviceMotionAvailable, !isRunning else { return }

        manager.deviceMotionUpdateInterval = updateInterval
        lastTimestamp = nil
        filter.reset()
        isRunning = true

        // The handler must be explicitly @Sendable, and must not carry the
        // CMDeviceMotion across.
        //
        // A closure formed inside a @MainActor type that captures self is
        // inferred to be @MainActor too. CoreMotion's handler is neither
        // Sendable nor isolated, so the runtime checks the isolation on entry
        // and traps the moment CoreMotion calls it from its own queue — before
        // a line of this code runs, which is why hopping to the main queue
        // inside the body changed nothing. It passed on iOS only while the
        // handler happened to be invoked on the main queue; watchOS used
        // another, and so did this queue.
        //
        // Marked @Sendable, no isolation is inferred and no check is inserted.
        // What then has to be true is that nothing unsendable crosses: the
        // sample is reduced to plain numbers here, on the delivery queue, and
        // only those go to the main actor. DispatchQueue.main rather than a
        // Task because it is FIFO, and samples whose order is lost would
        // corrupt every interval computed from them.
        let handler: @Sendable (CMDeviceMotion?, Error?) -> Void = { [weak self] motion, _ in
            guard let motion else { return }
            let sample = Sample(motion)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.consume(sample) }
            }
        }
        manager.startDeviceMotionUpdates(to: queue, withHandler: handler)
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

    private func consume(_ sample: Sample) {
        // Elapsed time comes from the sample timestamps rather than from
        // deviceMotionUpdateInterval, which is a request rather than a promise.
        defer { lastTimestamp = sample.timestamp }
        guard let previous = lastTimestamp else { return }

        let dt = sample.timestamp - previous
        guard dt > 0 else { return }

        // CMDeviceMotion.rotationRate is bias-corrected by CoreMotion's sensor
        // fusion. CMMotionManager.gyroData.rotationRate is the raw signal and
        // carries a bias that would walk the cursor across the screen while the
        // device sits still.
        //
        // Which device axis means "aim sideways" depends on how the device is
        // held, so gravity resolves it rather than a fixed axis being assumed.
        let (yaw, pitch) = MotionGeometry.resolve(
            rotationRate: sample.rotation,
            gravity: sample.gravity
        )

        // Both negated: a positive yaw turns the device left, and a positive
        // pitch aims it upward, while screen coordinates grow right and down.
        let (dx, dy) = filter.process(yaw: -yaw, pitch: -pitch, dt: dt)

        guard dx != 0 || dy != 0 else { return }
        onDelta?(dx, dy, dt * 1000)
    }
}

/// One motion sample as plain numbers.
///
/// CMDeviceMotion is a class and not Sendable, so it cannot be handed from
/// CoreMotion's queue to the main actor. Everything wanted from it is a few
/// doubles, which can.
private struct Sample: Sendable {
    let timestamp: TimeInterval
    let rotation: MotionGeometry.Vector3
    let gravity: MotionGeometry.Vector3

    init(_ m: CMDeviceMotion) {
        timestamp = m.timestamp
        rotation = .init(x: m.rotationRate.x, y: m.rotationRate.y, z: m.rotationRate.z)
        gravity = .init(x: m.gravity.x, y: m.gravity.y, z: m.gravity.z)
    }
}

#endif
