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
    enum Aim: Equatable {
        /// Nothing touching the surface.
        case idle
        /// A finger has landed on the pointer surface, but the cursor is still
        /// held still in case this turns out to be a tap.
        case arming
        /// Rotation is being forwarded.
        case aiming(Target)
    }

    enum Target: Equatable {
        case pointer
        case scroll
    }

    @Published var sensitivity: Double {
        didSet { applySensitivity() }
    }

    @Published var scrollSensitivity: Double {
        didSet { applySensitivity() }
    }

    @Published private(set) var aim: Aim = .idle

    private let source = MotionSource()
    private unowned let client: Client
    private var armTask: Task<Void, Never>?
    private var target: Target = .pointer

    /// The touch surface reports engagement in both input modes, and the
    /// closure that does so captures whatever mode was current when the view
    /// was built. Gating here rather than at the call site keeps that stale
    /// capture from mattering.
    private var isActive = false

    init(client: Client) {
        self.client = client

        let defaults = UserDefaults.standard
        self.sensitivity = defaults.object(forKey: "airSensitivity") as? Double
            ?? PointerFilter.Config().sensitivity
        self.scrollSensitivity = defaults.object(forKey: "airScrollSensitivity") as? Double
            ?? 900

        source.onDelta = { [weak self] dx, dy, dt in
            guard let self, case .aiming(let target) = self.aim else { return }
            switch target {
            case .pointer:
                self.client.move(dx: dx, dy: dy, dt: dt)
            case .scroll:
                self.client.scroll(dx: dx, dy: dy)
            }
        }

        applySensitivity()
    }

    var isAvailable: Bool { source.isAvailable }

    func activate() {
        isActive = true
        source.start()
    }

    func deactivate() {
        isActive = false
        armTask?.cancel()
        armTask = nil
        source.stop()
        aim = .idle
    }

    /// - Parameter target: which output the rotation should drive. Scrolling
    ///   needs a far gentler response than the pointer, so the two carry
    ///   separate sensitivities.
    func setEngaged(_ engaged: Bool, target: Target = .pointer) {
        guard isActive else { return }

        armTask?.cancel()
        armTask = nil

        guard engaged else {
            aim = .idle
            return
        }

        self.target = target
        applySensitivity()
        source.reengage()

        // Stay still until this is known not to be a tap. Both surfaces now
        // have a tap action — the pointer surface clicks, the strip right
        // clicks — so a press that turns out to be a tap must not have moved
        // anything first.
        aim = .arming

        armTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(GestureTiming.tapMaxDuration))
            guard let self, !Task.isCancelled, self.aim == .arming else { return }

            self.aim = .aiming(target)
            // Discard whatever accumulated during the pause, or the rotation
            // made while deciding to hold arrives as a jump the moment motion
            // comes alive.
            self.source.reengage()
        }
    }

    private func applySensitivity() {
        source.config.sensitivity = target == .scroll ? scrollSensitivity : sensitivity
    }

    func persistSensitivity() {
        let defaults = UserDefaults.standard
        defaults.set(sensitivity, forKey: "airSensitivity")
        defaults.set(scrollSensitivity, forKey: "airScrollSensitivity")
    }
}

enum InputMode: String, CaseIterable, Identifiable {
    case trackpad = "Trackpad"
    case airMouse = "Air Mouse"

    var id: String { rawValue }
}
