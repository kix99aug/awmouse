import UIKit

/// Raw multi-touch trackpad surface.
///
/// SwiftUI's `DragGesture` is a single-touch abstraction with no finger count,
/// so the gesture set here (two-finger scroll, three-finger middle click) has to
/// be built on UIKit touch handling directly. This is effectively a small
/// trackpad driver.
final class TrackpadSurface: UIView {
    var onMove: ((Double, Double, Double) -> Void)?
    var onScroll: ((Double, Double) -> Void)?
    var onButton: ((MouseButton, Bool) -> Void)?
    var onClick: ((MouseButton) -> Void)?

    /// Fires when the surface goes from untouched to touched and back. Air
    /// Mouse mode uses it as the clutch: rotation drives the cursor only while
    /// a finger rests here.
    var onEngageChanged: ((Bool) -> Void)?

    /// When false, finger translation no longer moves the cursor — Air Mouse
    /// mode takes that over. Scrolling, taps, and drag still come from touch,
    /// so the rest of the gesture set is unaffected.
    var emitsTouchMotion = true

    /// How far the touch may travel and still count as a tap.
    private let tapSlop: CGFloat = 10

    /// Shared with Air Mouse mode, which waits exactly this long before letting
    /// rotation move the cursor. See `GestureTiming`.
    private let tapMaxDuration = GestureTiming.tapMaxDuration

    /// A tap followed by a press this soon begins the second half of a double
    /// tap.
    private let dragArmWindow = GestureTiming.dragArmWindow

    /// Travel required before committing to move-vs-scroll. Fingers rarely land
    /// on the same event, so a brief wait lets a two-finger gesture be seen as
    /// one rather than starting life as a cursor move.
    private let modeThreshold: CGFloat = 3

    private enum Mode {
        case undecided
        case moving
        case scrolling
        /// The second press of a double tap, before it is known whether it will
        /// be held (a selection drag) or released (a right click).
        case dragPending
        case dragging
    }

    private var active: Set<UITouch> = []
    private var mode: Mode = .undecided
    private var maxFingers = 0
    private var startedAt = Date()
    private var lastSampleAt = Date()
    private var travelled: CGFloat = 0
    private var lastCentroid: CGPoint = .zero
    private var pending = CGVector.zero
    private var dragArmedUntil = Date.distantPast
    private var holdTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Without this the view only ever receives a single touch, and every
        // multi-finger gesture below silently degrades to one finger.
        isMultipleTouchEnabled = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let starting = active.isEmpty
        active.formUnion(touches)

        if starting {
            onEngageChanged?(true)
            startedAt = Date()
            lastSampleAt = startedAt
            travelled = 0
            pending = .zero
            mode = .undecided
            maxFingers = active.count

            if active.count == 1 && Date() < dragArmedUntil {
                dragArmedUntil = .distantPast
                beginDragPending()
            }
        } else {
            maxFingers = max(maxFingers, active.count)

            // A second finger means this was never half of a double tap after
            // all — the first finger just landed fractionally earlier.
            if mode == .dragPending || mode == .dragging {
                cancelHold()
                if mode == .dragging { onButton?(.left, false) }
                mode = .undecided
            }
        }

        // The centroid jumps whenever the touch set changes. Re-anchor so that
        // jump is not reported as movement.
        lastCentroid = centroid()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let now = Date()
        let c = centroid()
        let dx = c.x - lastCentroid.x
        let dy = c.y - lastCentroid.y
        lastCentroid = c

        travelled += hypot(dx, dy)
        let dt = now.timeIntervalSince(lastSampleAt) * 1000
        lastSampleAt = now

        switch mode {
        case .dragPending:
            // Hold the movement until the press resolves into a drag; emitting
            // now would move the cursor for what may turn out to be a click.
            pending.dx += dx
            pending.dy += dy

        case .undecided:
            pending.dx += dx
            pending.dy += dy
            guard travelled >= modeThreshold else { return }

            mode = active.count >= 2 ? .scrolling : .moving
            dispatch(dx: pending.dx, dy: pending.dy, dt: dt)
            pending = .zero

        default:
            dispatch(dx: dx, dy: dy, dt: dt)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        active.subtract(touches)
        guard active.isEmpty else {
            lastCentroid = centroid()
            return
        }

        let duration = Date().timeIntervalSince(startedAt)
        cancelHold()

        switch mode {
        case .dragging:
            onButton?(.left, false)

        case .dragPending:
            // Released before the hold completed, so the double tap was not the
            // start of a selection.
            onClick?(.right)

        default:
            if travelled < tapSlop && duration < tapMaxDuration {
                switch maxFingers {
                case 1:
                    onClick?(.left)
                    // Arm the second half of a double tap.
                    dragArmedUntil = Date().addingTimeInterval(dragArmWindow)
                case 2:
                    onClick?(.right)
                default:
                    onClick?(.middle)
                }
            }
        }

        reset()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        active.subtract(touches)
        guard active.isEmpty else {
            lastCentroid = centroid()
            return
        }
        cancelHold()
        if mode == .dragging {
            onButton?(.left, false)
        }
        reset()
    }

    // MARK: - Double tap resolution

    /// Starts the second half of a double tap. Which gesture it becomes is
    /// decided by time rather than by movement, because in Air Mouse mode the
    /// cursor is driven by rotation and the finger never moves at all — a
    /// travel-based test would never fire there.
    private func beginDragPending() {
        mode = .dragPending
        holdTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(GestureTiming.tapMaxDuration))
            guard let self, !Task.isCancelled, self.mode == .dragPending else { return }

            self.mode = .dragging
            self.onButton?(.left, true)

            // Release the movement withheld while the press was undecided.
            if self.pending != .zero {
                self.dispatch(dx: self.pending.dx, dy: self.pending.dy, dt: 8)
                self.pending = .zero
            }
        }
    }

    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
    }

    // MARK: - Helpers

    private func dispatch(dx: CGFloat, dy: CGFloat, dt: Double) {
        switch mode {
        case .scrolling:
            onScroll?(Double(dx), Double(dy))
        case .moving, .dragging:
            guard emitsTouchMotion else { return }
            onMove?(Double(dx), Double(dy), dt)
        case .undecided, .dragPending:
            break
        }
    }

    private func centroid() -> CGPoint {
        guard !active.isEmpty else { return lastCentroid }
        var sx: CGFloat = 0
        var sy: CGFloat = 0
        for touch in active {
            let p = touch.location(in: self)
            sx += p.x
            sy += p.y
        }
        let n = CGFloat(active.count)
        return CGPoint(x: sx / n, y: sy / n)
    }

    /// Ends the touch sequence. Reached from both `touchesEnded` and
    /// `touchesCancelled`, and only once the last finger has lifted, so the
    /// disengage notification belongs here rather than in each caller.
    private func reset() {
        mode = .undecided
        maxFingers = 0
        travelled = 0
        pending = .zero
        onEngageChanged?(false)
    }
}
