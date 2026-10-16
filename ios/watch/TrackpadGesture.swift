import Foundation
import SwiftUI
import WatchBridge

/// Turns fingers on the watch face into cursor movement and clicks.
///
///     one finger, dragging         move the cursor
///     one finger, tap              left click
///     one finger, tap twice        double click
///     two fingers, tap             right click
///     two fingers, tap twice       middle click
///     tap, then hold and drag      drag with the left button down
///
/// The same set as the phone's trackpad, and deliberately so: the two surfaces
/// are the same instrument and there is nothing to gain from making a hand
/// learn each separately.
///
/// Counting fingers is why this reads SpatialEventGesture rather than
/// DragGesture. DragGesture reports one finger, so a second was invisible and
/// right click had to be a timed hold — which fired whenever a finger rested
/// before moving. MagnifyGesture and RotateGesture, the other ways to notice a
/// second finger, are both unavailable on watchOS.
///
/// A class, and not state inside the view, because resolving a press takes a
/// timer: the press that becomes a drag is decided while the finger is still
/// down. A `Task` living in a `View` struct captures a copy of that struct and
/// reaches back into its `@State` from outside any view update, which SwiftUI
/// does not define and Swift 6 is entitled to trap. Here the state has an
/// owner with a lifetime.
@MainActor
final class TrackpadGesture: ObservableObject {
    /// Shown as a highlight, so a press that registered looks different from
    /// one that did not.
    @Published private(set) var pressing = false

    /// How far the finger may travel and still be a tap. Generous next to the
    /// phone's: a fingertip covers a sixth of this screen, and nobody presses
    /// a watch precisely.
    private let slop: CGFloat = 14
    private let tapMaxDuration: TimeInterval = 0.3

    /// How long after a tap a second press still makes a double tap.
    private let doubleTapWindow: TimeInterval = 0.3

    /// Three fingers on a 46 mm screen is a stretch, so the middle button is
    /// a second two-finger tap instead. That means the right click has to wait
    /// out the window before it can be sent — otherwise every middle click
    /// would be a right click first, which opens a context menu. The same
    /// trade the phone's strip makes, for the same pair of buttons.
    private var pendingRightClick: Task<Void, Never>?
    private var twoFingerArmedUntil = Date.distantPast

    private enum Mode {
        case undecided
        case moving
        /// The second press of a double tap, before it is known whether it
        /// will be held — a selection drag — or released, which makes the
        /// second click of a double click.
        case dragPending
        case dragging
    }

    private unowned let controller: WatchController

    private var mode: Mode = .undecided
    private var mostFingers = 0
    private var startedAt = Date()
    private var lastSampleAt = Date()
    private var travelled: CGFloat = 0
    private var holdTask: Task<Void, Never>?

    /// The finger the cursor follows: the first one down. Tracked by identity
    /// rather than by position, so a second finger landing does not hand the
    /// cursor to whichever touch the system happens to list first.
    private var primary: SpatialEventCollection.Event.ID?
    private var lastPoint: CGPoint = .zero

    /// When a second press would still count as the other half of a double
    /// tap.
    private var doubleTapArmedUntil = Date.distantPast

    init(controller: WatchController) {
        self.controller = controller
    }

    /// Every change to the set of fingers on the glass, including the ones
    /// that lift. SwiftUI sends an empty collection for nothing at all.
    func update(_ events: SpatialEventCollection) {
        let active = events.filter { $0.phase == .active }

        guard !active.isEmpty else {
            if primary != nil { finish() }
            return
        }

        guard let first = primary else {
            begin(with: active)
            return
        }

        mostFingers = max(mostFingers, active.count)

        // The cursor follows one finger. When a second lands, this press is a
        // right or middle click and moving the cursor under it would be wrong.
        guard let moved = active.first(where: { $0.id == first }), mostFingers == 1 else { return }

        let now = Date()
        let dx = moved.location.x - lastPoint.x
        let dy = moved.location.y - lastPoint.y
        lastPoint = moved.location
        travelled += hypot(dx, dy)

        let dt = now.timeIntervalSince(lastSampleAt) * 1000
        lastSampleAt = now

        if travelled >= slop {
            switch mode {
            case .undecided:
                mode = .moving
            case .dragPending:
                // The second press moved before its timer fired. That is a
                // selection starting, and waiting out the timer would lose
                // the first part of it.
                beginDragging()
            default:
                break
            }
        }

        guard dx != 0 || dy != 0 else { return }
        switch mode {
        case .moving, .dragging:
            controller.trackpadMoved(dx: Double(dx), dy: Double(dy), dt: dt)
        case .undecided, .dragPending:
            // Withheld on purpose: a press that has not been resolved may yet
            // become a drag, and the cursor must not creep in the meantime.
            break
        }
    }

    /// All fingers gone, by whatever route.
    func cancelled() {
        if primary != nil { finish() }
    }

    /// The trackpad is leaving the screen with a finger possibly still on it
    /// — the link dropped mid-gesture and the watch is showing its state
    /// instead. Whatever was under way is dropped without clicking, except a
    /// held button, which is let go: the computer would otherwise go on
    /// holding it down, selecting, until something else released it.
    func abandon() {
        cancelHold()
        if case .dragging = mode { controller.press(.left, down: false) }
        primary = nil
        pressing = false
        travelled = 0
        mostFingers = 0
        mode = .undecided
    }

    // MARK: - Press lifecycle

    private func begin(with active: [SpatialEventCollection.Event]) {
        let now = Date()
        primary = active[0].id
        lastPoint = active[0].location
        mostFingers = active.count
        startedAt = now
        lastSampleAt = now
        travelled = 0
        pressing = true

        if now <= doubleTapArmedUntil && active.count == 1 {
            mode = .dragPending
            beginDragPending()
        } else {
            mode = .undecided
        }
        doubleTapArmedUntil = .distantPast
    }

    private func finish() {
        cancelHold()

        let duration = Date().timeIntervalSince(startedAt)
        let wasTap = travelled < slop && duration < tapMaxDuration
        let finished = mode
        let fingers = mostFingers

        primary = nil
        pressing = false
        travelled = 0
        mostFingers = 0
        mode = .undecided

        switch finished {
        case .dragging:
            controller.press(.left, down: false)

        case .dragPending:
            // Released before the hold completed, so this was the second tap
            // of a plain double tap. Sending its own left click is what makes
            // the pair read as a double click on the host, which counts them.
            controller.click(.left)

        case .undecided, .moving:
            guard wasTap else { return }
            switch fingers {
            case 1:
                controller.click(.left)
                // Arm the second half of a double tap.
                doubleTapArmedUntil = Date().addingTimeInterval(doubleTapWindow)
            case 2:
                resolveTwoFingerTap()
            default:
                // Three fingers is hard to land on a watch, but if it happens
                // it can only have meant the middle button.
                cancelPendingRightClick()
                controller.click(.middle)
            }
        }
    }

    /// A two-finger tap is a right click unless a second one follows, which
    /// makes it a middle click. Which it is cannot be known until the window
    /// has passed, so the right click is held back rather than sent and
    /// regretted.
    private func resolveTwoFingerTap() {
        let now = Date()
        if now <= twoFingerArmedUntil {
            cancelPendingRightClick()
            twoFingerArmedUntil = .distantPast
            controller.click(.middle)
            return
        }

        twoFingerArmedUntil = now.addingTimeInterval(doubleTapWindow)
        cancelPendingRightClick()
        pendingRightClick = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.doubleTapWindow))
            guard !Task.isCancelled else { return }
            self.pendingRightClick = nil
            self.controller.click(.right)
        }
    }

    private func cancelPendingRightClick() {
        pendingRightClick?.cancel()
        pendingRightClick = nil
    }

    /// The second press, held down: after a tap's worth of time it is no
    /// longer a tap, so it becomes a selection drag.
    private func beginDragPending() {
        holdTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.tapMaxDuration))
            guard !Task.isCancelled, self.pressing, case .dragPending = self.mode else { return }
            self.beginDragging()
        }
    }

    private func beginDragging() {
        cancelHold()
        mode = .dragging
        controller.press(.left, down: true)
    }

    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
    }
}
