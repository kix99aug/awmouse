import UIKit

/// The right-edge strip: tap for right click, double tap for middle click,
/// hold to scroll.
///
/// Built on UIKit touch handling rather than a SwiftUI `DragGesture` for the
/// same reason the main surface is. A tap that never moves may produce no
/// change callback at all, so gesture state ends up being inferred from
/// whatever the previous gesture left behind — which is exactly the kind of
/// ambiguity that makes a tap emit the wrong click.
final class StripSurface: UIView {
    /// Finger-driven scrolling, used in Trackpad mode.
    var onScroll: ((Double, Double) -> Void)?

    /// Right click.
    var onTap: (() -> Void)?

    /// Middle click.
    var onDoubleTap: (() -> Void)?

    /// Clutch for Air Mouse mode, where scrolling comes from rotation.
    var onEngageChanged: ((Bool) -> Void)?

    /// When false, finger travel no longer scrolls — Air Mouse takes it over —
    /// and is used only to tell a hold from a tap.
    var emitsTouchScroll = true

    private let tapSlop: CGFloat = 10
    private let tapMaxDuration = GestureTiming.tapMaxDuration
    private let doubleTapWindow = GestureTiming.dragArmWindow

    private var active: Set<UITouch> = []
    private var startedAt = Date()
    private var lastY: CGFloat = 0
    private var travelled: CGFloat = 0
    private var pending: CGFloat = 0
    private var scrolling = false

    /// A tap waits to see whether a second one follows. Right click carries the
    /// delay that left click refuses to: it is rare enough that a third of a
    /// second costs little, whereas the same wait on every left click is what
    /// the whole gesture scheme exists to avoid.
    private var tapTask: Task<Void, Never>?
    private var secondTap = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let starting = active.isEmpty
        active.formUnion(touches)
        guard starting, let touch = touches.first else { return }

        // Landing while a tap is still undecided makes the pair a double tap.
        secondTap = tapTask != nil
        tapTask?.cancel()
        tapTask = nil

        startedAt = Date()
        lastY = touch.location(in: self).y
        travelled = 0
        pending = 0
        scrolling = false

        onEngageChanged?(true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = active.first else { return }

        let y = touch.location(in: self).y
        let dy = y - lastY
        lastY = y
        travelled += abs(dy)

        guard emitsTouchScroll else { return }

        // Withhold scrolling until the touch is too far along to be a tap, or a
        // right click would nudge the page on its way out.
        pending += dy
        guard travelled >= tapSlop else { return }

        scrolling = true
        onScroll?(0, Double(pending))
        pending = 0
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        active.subtract(touches)
        guard active.isEmpty else { return }

        let duration = Date().timeIntervalSince(startedAt)
        let wasTap = !scrolling && travelled < tapSlop && duration < tapMaxDuration

        onEngageChanged?(false)

        guard wasTap else {
            secondTap = false
            return
        }

        if secondTap {
            secondTap = false
            onDoubleTap?()
            return
        }

        let window = doubleTapWindow
        tapTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(window))
            guard let self, !Task.isCancelled else { return }
            // Cleared before firing, so a tap arriving during the click is not
            // mistaken for the second half of this one.
            self.tapTask = nil
            self.onTap?()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        active.subtract(touches)
        guard active.isEmpty else { return }
        secondTap = false
        onEngageChanged?(false)
    }
}
