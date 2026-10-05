import Foundation
import SwiftUI

/// Turns a finger on the watch face into cursor movement and clicks.
///
/// A class, and not state inside the view, because resolving a press takes a
/// timer: the hold that becomes a right click fires while the finger is still
/// down. A `Task` living in a `View` struct captures a copy of that struct and
/// reaches back into its `@State` from outside any view update, which SwiftUI
/// does not define and Swift 6 is entitled to trap. Here the state has an
/// owner with a lifetime.
@MainActor
final class TrackpadGesture: ObservableObject {
    /// Shown as a highlight, so a press that registered looks different from
    /// one that did not.
    @Published private(set) var pressing = false

    /// How far the finger may travel and still be a tap or a hold. Generous
    /// next to the phone's: a fingertip covers a sixth of this screen, and
    /// nobody presses a watch precisely.
    private let slop: CGFloat = 14
    private let tapMaxDuration: TimeInterval = 0.3
    private let holdDuration: Duration = .milliseconds(500)

    private unowned let controller: WatchController

    private var lastPoint: CGPoint?
    private var lastSampleAt = Date()
    private var startedAt = Date()
    private var travelled: CGFloat = 0
    private var holdTask: Task<Void, Never>?
    private var resolved = false

    init(controller: WatchController) {
        self.controller = controller
    }

    func changed(to point: CGPoint) {
        let now = Date()

        guard let previous = lastPoint else {
            lastPoint = point
            lastSampleAt = now
            startedAt = now
            travelled = 0
            resolved = false
            pressing = true
            beginHold()
            return
        }

        let dx = point.x - previous.x
        let dy = point.y - previous.y
        lastPoint = point
        travelled += hypot(dx, dy)

        let dt = now.timeIntervalSince(lastSampleAt) * 1000
        lastSampleAt = now

        // Past the slop this is a drag, and a hold is no longer on the cards.
        if travelled >= slop {
            cancelHold()
        }
        guard dx != 0 || dy != 0 else { return }
        controller.trackpadMoved(dx: Double(dx), dy: Double(dy), dt: dt)
    }

    func ended() {
        cancelHold()
        let duration = Date().timeIntervalSince(startedAt)
        let wasTap = !resolved && travelled < slop && duration < tapMaxDuration

        lastPoint = nil
        pressing = false
        travelled = 0
        resolved = false

        if wasTap { controller.click(.left) }
    }

    /// A press that stays put long enough becomes a right click, and says so
    /// through the Taptic engine at that moment rather than on release — the
    /// hold is what the user is waiting to feel.
    private func beginHold() {
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled, self.pressing, self.travelled < self.slop else { return }
            self.resolved = true
            self.controller.click(.right)
        }
    }

    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
    }
}
