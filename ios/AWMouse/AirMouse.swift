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
    @Published var sensitivity: Double {
        didSet { source.config.sensitivity = sensitivity }
    }

    @Published private(set) var isEngaged = false

    private let source = MotionSource()
    private unowned let client: Client

    init(client: Client) {
        self.client = client
        self.sensitivity = UserDefaults.standard.object(forKey: "airSensitivity") as? Double
            ?? PointerFilter.Config().sensitivity

        source.config.sensitivity = sensitivity
        source.onDelta = { [weak self] dx, dy, dt in
            guard let self, self.isEngaged else { return }
            self.client.move(dx: dx, dy: dy, dt: dt)
        }
    }

    var isAvailable: Bool { source.isAvailable }

    func activate() {
        source.start()
    }

    func deactivate() {
        source.stop()
        isEngaged = false
    }

    func setEngaged(_ engaged: Bool) {
        guard engaged != isEngaged else { return }
        isEngaged = engaged
        if engaged {
            // Drop smoothing state accumulated while disengaged, so motion from
            // before the clutch cannot arrive as a jump on the first sample.
            source.reengage()
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
