import SwiftUI

struct TrackpadView: View {
    @EnvironmentObject private var client: Client
    @EnvironmentObject private var air: AirMouse
    @State private var mode: InputMode = .trackpad

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $mode) {
                ForEach(InputMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Trackpad(client: client, air: air, mode: mode)
                .background(surfaceTint)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(surfaceLabel)
                .padding(12)

            if mode == .airMouse {
                sensitivity
            }

            legend
        }
        .background(Color(.systemBackground))
        .onChange(of: mode) { _, newMode in
            newMode == .airMouse ? air.activate() : air.deactivate()
        }
        .onDisappear { air.deactivate() }
    }

    /// Engaging is otherwise invisible in Air Mouse mode — the finger isn't
    /// moving, so nothing on screen would tell you the clutch is down. The
    /// mid-tone during `arming` is what keeps the pause before motion reading
    /// as a deliberate wait rather than as lag.
    private var surfaceTint: Color {
        guard mode == .airMouse else { return Color(.secondarySystemBackground) }
        switch air.aim {
        case .idle: return Color(.secondarySystemBackground)
        case .arming: return Color.accentColor.opacity(0.08)
        case .aiming: return Color.accentColor.opacity(0.18)
        }
    }

    private var surfaceLabel: some View {
        Text(surfaceText)
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .animation(.none, value: surfaceText)
    }

    private var surfaceText: String {
        guard mode == .airMouse else { return "trackpad" }
        switch air.aim {
        case .idle: return "hold to aim"
        case .arming: return "release to click"
        case .aiming: return "aiming"
        }
    }

    private var sensitivity: some View {
        HStack(spacing: 10) {
            Image(systemName: "tortoise.fill")
            Slider(
                value: $air.sensitivity,
                in: 500...8000,
                onEditingChanged: { editing in
                    if !editing { air.persistSensitivity() }
                }
            )
            Image(systemName: "hare.fill")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    private var legend: some View {
        VStack(spacing: 6) {
            Grid(horizontalSpacing: 14, verticalSpacing: 3) {
                if mode == .airMouse {
                    row("hold anywhere", "aim by tilting")
                } else {
                    row("one finger drag", "move cursor")
                }
                row("one finger tap", "left click")
                row("two fingers", "scroll · tap for right click")
                row("three fingers", "middle click")
                row("tap then hold", "drag")
            }
            .font(.caption2)

            if mode == .airMouse && !air.isAvailable {
                Text("no motion sensor here — run on a device")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

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
    let air: AirMouse
    let mode: InputMode

    func makeUIView(context: Context) -> TrackpadSurface {
        let surface = TrackpadSurface()
        surface.onMove = { dx, dy, dt in client.move(dx: dx, dy: dy, dt: dt) }
        surface.onScroll = { dx, dy in client.scroll(dx: dx, dy: dy) }
        surface.onButton = { button, down in client.button(button, down: down) }
        surface.onClick = { button in client.click(button) }
        surface.onEngageChanged = { engaged in air.setEngaged(engaged) }
        surface.emitsTouchMotion = mode == .trackpad
        return surface
    }

    func updateUIView(_ uiView: TrackpadSurface, context: Context) {
        uiView.emitsTouchMotion = mode == .trackpad
    }
}
