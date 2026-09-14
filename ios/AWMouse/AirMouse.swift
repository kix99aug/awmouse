import Foundation
import MotionInput

/// Drives the cursor from device rotation instead of finger translation.
///
/// Motion is forwarded only while a finger is held on the surface. Gyroscopes
/// pick up every incidental arm movement, so without an explicit engage the
/// cursor wanders whenever the phone is merely carried — and retrofitting a
/// clutch afterwards means redoing the gesture layer.
@MainActor
final class AirMouse: ObservableObject {
    /// What the clutch is currently doing.
    enum Aim {
        /// Nothing touching the surface.
        case idle
        /// A finger has landed, but the cursor is still held still in case this
        /// turns out to be a tap.
        case arming
        /// Held long enough to be a deliberate hold; rotation now moves the
        /// cursor.
        case aiming
    }

    @Published var sensitivity: Double {
        didSet { source.config.sensitivity = sensitivity }
    }

    @Published private(set) var aim: Aim = .idle

    private let source = MotionSource()
    private unowned let client: Client
    private var armTask: Task<Void, Never>?

    init(client: Client) {
        self.client = client
        self.sensitivity = UserDefaults.standard.object(forKey: "airSensitivity") as? Double
            ?? PointerFilter.Config().sensitivity

        source.config.sensitivity = sensitivity
        source.onDelta = { [weak self] dx, dy, dt in
            guard let self, self.aim == .aiming else { return }
            self.client.move(dx: dx, dy: dy, dt: dt)
        }
    }

    var isAvailable: Bool { source.isAvailable }

    func activate() {
        source.start()
    }

    func deactivate() {
        armTask?.cancel()
        armTask = nil
        source.stop()
        aim = .idle
    }

    func setEngaged(_ engaged: Bool) {
        guard engaged != (aim != .idle) else { return }

        armTask?.cancel()
        armTask = nil

        guard engaged else {
            aim = .idle
            return
        }

        // Hold the cursor still until this is known not to be a tap. Without
        // the pause, tapping to click drags the cursor off whatever it was
        // aimed at during the press.
        aim = .arming
        source.reengage()

        armTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(GestureTiming.tapMaxDuration))
            guard let self, !Task.isCancelled, self.aim == .arming else { return }

            self.aim = .aiming
            // Discard whatever accumulated during the pause, or the rotation
            // made while deciding to hold arrives as a jump the moment the
            // cursor comes alive.
            self.source.reengage()
        }
    }

    func persistSensitivity() {
        UserDefaults.standard.set(sensitivity, forKey: "airSensitivity")
    }
}

enum InputMode: String, CaseIterable, Identifiable {
    case trackpad = "Trackpad"
    case airMouse = "Air Mouse"

    var id: String { rawValue }
}
