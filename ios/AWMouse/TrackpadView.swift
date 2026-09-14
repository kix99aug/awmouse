import SwiftUI

struct TrackpadView: View {
    @EnvironmentObject private var client: Client

    var body: some View {
        VStack(spacing: 0) {
            Trackpad(client: client)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(
                    Text("trackpad")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                )
                .padding(12)

            legend
        }
        .background(Color(.systemBackground))
    }

    private var legend: some View {
        VStack(spacing: 6) {
            Grid(horizontalSpacing: 14, verticalSpacing: 3) {
                row("one finger", "move · tap to click")
                row("two fingers", "scroll · tap for right click")
                row("three fingers", "middle click")
                row("tap then hold", "drag")
            }
            .font(.caption2)

            Button("Disconnect") { client.disconnect() }
                .font(.caption)
                .padding(.top, 4)
        }
        .padding(.bottom, 12)
    }

    private func row(_ gesture: String, _ meaning: String) -> some View {
        GridRow {
            Text(gesture)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(meaning)
                .foregroundStyle(.tertiary)
                .gridColumnAlignment(.leading)
        }
    }
}

/// Bridges the UIKit trackpad surface into SwiftUI. The gesture recognition
/// itself lives in `TrackpadSurface` — SwiftUI gestures cannot report finger
/// count.
private struct Trackpad: UIViewRepresentable {
    let client: Client

    func makeUIView(context: Context) -> TrackpadSurface {
        let surface = TrackpadSurface()
        surface.onMove = { dx, dy, dt in client.move(dx: dx, dy: dy, dt: dt) }
        surface.onScroll = { dx, dy in client.scroll(dx: dx, dy: dy) }
        surface.onButton = { button, down in client.button(button, down: down) }
        surface.onClick = { button in client.click(button) }
        return surface
    }

    func updateUIView(_ uiView: TrackpadSurface, context: Context) {}
}
