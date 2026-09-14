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

    /// How far the touch may travel and still count as a tap.
    private let tapSlop: CGFloat = 10
    private let tapMaxDuration: TimeInterval = 0.25

    /// Travel required before committing to move-vs-scroll. Fingers rarely land
    /// on the same event, so a brief wait lets a two-finger gesture be seen as
    /// one rather than starting life as a cursor move.
    private let modeThreshold: CGFloat = 3

    /// A tap followed by a press this soon becomes a drag, matching the
    /// trackpad convention of double-tap-and-hold.
    private let dragArmWindow: TimeInterval = 0.3

    private enum Mode { case undecided, moving, scrolling, dragging }

    private var active: Set<UITouch> = []
    private var mode: Mode = .undecided
    private var maxFingers = 0
    private var startedAt = Date()
    private var lastSampleAt = Date()
    private var travelled: CGFloat = 0
    private var lastCentroid: CGPoint = .zero
    private var pending = CGVector.zero
    private var dragArmedUntil = Date.distantPast

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
            startedAt = Date()
            lastSampleAt = startedAt
            travelled = 0
            pending = .zero
            mode = .undecided
            maxFingers = active.count

            if active.count == 1 && Date() < dragArmedUntil {
                dragArmedUntil = .distantPast
                mode = .dragging
                onButton?(.left, true)
            }
        } else {
            maxFingers = max(maxFingers, active.count)

            // A second finger means this was never a drag after all — the first
            // finger just landed fractionally earlier.
            if mode == .dragging && active.count >= 2 {
                onButton?(.left, false)
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

        if mode == .undecided {
            pending.dx += dx
            pending.dy += dy
            guard travelled >= modeThreshold else { return }

            mode = active.count >= 2 ? .scrolling : .moving
            dispatch(dx: pending.dx, dy: pending.dy, dt: dt)
            pending = .zero
            return
        }

        dispatch(dx: dx, dy: dy, dt: dt)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        active.subtract(touches)
        guard active.isEmpty else {
            lastCentroid = centroid()
            return
        }

        let duration = Date().timeIntervalSince(startedAt)

        if mode == .dragging {
            onButton?(.left, false)
        } else if travelled < tapSlop && duration < tapMaxDuration {
            switch maxFingers {
            case 1:
                onClick?(.left)
                // Arm the drag window: a press arriving now becomes a drag.
                dragArmedUntil = Date().addingTimeInterval(dragArmWindow)
            case 2:
                onClick?(.right)
            default:
                onClick?(.middle)
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
        if mode == .dragging {
            onButton?(.left, false)
        }
        reset()
    }

    // MARK: - Helpers

    private func dispatch(dx: CGFloat, dy: CGFloat, dt: Double) {
        switch mode {
        case .scrolling:
            onScroll?(Double(dx), Double(dy))
        case .moving, .dragging:
            onMove?(Double(dx), Double(dy), dt)
        case .undecided:
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

    private func reset() {
        mode = .undecided
        maxFingers = 0
        travelled = 0
        pending = .zero
    }
}
