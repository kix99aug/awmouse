import SwiftUI

/// The watch face used as a trackpad: drag to move, tap to click, press and
/// hold to right click.
///
/// Right click is the hold rather than a second tap. A double tap would put
/// its wait on every left click, which is the trade the phone refused for the
/// same reason; holding costs nothing until someone actually holds. And there
/// is no room here for the phone's answer — a second target along one edge —
/// on a screen this size.
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
        RoundedRectangle(cornerRadius: 12)
            .fill(gesture.pressing ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.18))
            .overlay(label)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture.changed(to: $0.location) }
                    .onEnded { _ in gesture.ended() }
            )
    }

    @ViewBuilder private var label: some View {
        if !gesture.pressing {
            Text("drag · tap · hold")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}
