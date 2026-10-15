import SwiftUI

/// The watch face used as a trackpad: drag to move, tap to click, two fingers
/// for a right click and two fingers twice for a middle click.
///
/// The view is only the surface. Resolving what a press meant lives in
/// `TrackpadGesture`, because it needs a timer and state that outlives a view
/// update.
struct TrackpadPad: View {
    @StateObject private var gesture: TrackpadGesture

    init(controller: WatchController) {
        _gesture = StateObject(wrappedValue: TrackpadGesture(controller: controller))
    }

    var body: some View {
        // ContainerRelativeShape rather than a fixed radius: the pad is now
        // the whole display, and a watch display is a rounded rectangle whose
        // corners differ by model. This follows whatever the screen does.
        ContainerRelativeShape()
            .fill(gesture.pressing ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.18))
            .overlay(label)
            .contentShape(Rectangle())
            // SpatialEventGesture rather than DragGesture: it is the only one
            // on watchOS that reports more than one finger, and the finger
            // count is what tells a left click from a right or a middle.
            .gesture(
                SpatialEventGesture()
                    .onChanged { gesture.update($0) }
                    .onEnded { _ in gesture.cancelled() }
            )
    }

    /// The whole gesture set, written out. There is nowhere else to put it —
    /// a watch has no room for a help screen anyone would find — and it costs
    /// nothing, because it is only drawn while the surface is idle.
    @ViewBuilder private var label: some View {
        if !gesture.pressing {
            VStack(alignment: .leading, spacing: 1) {
                row("drag", "move")
                row("tap", "left click")
                row("tap twice", "double click")
                row("tap, hold", "drag to select")
                row("2 fingers", "right click")
                row("2 fingers twice", "middle click")
                row("crown", "scroll")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
    }

    private func row(_ gesture: String, _ meaning: String) -> some View {
        HStack(spacing: 4) {
            Text(gesture)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)
            Text(meaning)
        }
    }
}
