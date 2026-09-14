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

            HStack(spacing: 8) {
                Trackpad(client: client, air: air, mode: mode)
                    .background(surfaceTint)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(surfaceLabel)

                ScrollStrip(client: client, air: air, mode: mode)
                    .frame(width: 66)
            }
            .padding(12)

            if mode == .airMouse {
                sliders
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
        case .idle, .aiming(.scroll): return Color(.secondarySystemBackground)
        case .arming: return Color.accentColor.opacity(0.08)
        case .aiming(.pointer): return Color.accentColor.opacity(0.18)
        }
    }

    private var surfaceLabel: some View {
        Text(surfaceText)
            .font(.footnote)
            .foregroundStyle(.tertiary)
    }

    private var surfaceText: String {
        guard mode == .airMouse else { return "trackpad" }
        switch air.aim {
        case .idle, .aiming(.scroll): return "hold to aim"
        case .arming: return "release to click"
        case .aiming(.pointer): return "aiming"
        }
    }

    private var sliders: some View {
        VStack(spacing: 2) {
            slider("pointer", value: $air.sensitivity, range: 500...8000)
            slider("scroll", value: $air.scrollSensitivity, range: 150...3000)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    private func slider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .frame(width: 46, alignment: .trailing)
            Slider(value: value, in: range, onEditingChanged: { editing in
                if !editing { air.persistSensitivity() }
            })
        }
    }

    private var legend: some View {
        VStack(spacing: 6) {
            Grid(horizontalSpacing: 14, verticalSpacing: 3) {
                if mode == .airMouse {
                    row("hold", "aim by tilting")
                    row("strip held", "scroll by tilting")
                } else {
                    row("drag", "move cursor")
                    row("strip held", "scroll by sliding")
                }
                row("tap", "left click")
                row("strip tap", "right click")
                row("double tap", "double click")
                row("double tap, hold", "drag to select")
                row("three finger tap", "middle click")
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

/// The right-edge strip: tap for a right click, hold to scroll.
///
/// Both live here so that the whole gesture set is reachable with one finger.
/// Two-finger scrolling and two-finger right click still work, but they are
/// awkward when the same hand is holding the phone, so neither is required.
///
/// Only needs to know whether a finger rests on it and roughly how far it has
/// moved — no finger count — so a plain SwiftUI gesture suffices, unlike the
/// main surface which has to drop to UIKit.
private struct ScrollStrip: View {
    let client: Client
    let air: AirMouse
    let mode: InputMode

    @State private var startedAt: Date?
    @State private var lastY: CGFloat = 0
    @State private var travelled: CGFloat = 0
    @State private var pending: CGFloat = 0

    /// Matches the main surface: a touch that travels less than this and is
    /// released quickly is a tap.
    private let tapSlop: CGFloat = 10

    private var engaged: Bool { startedAt != nil }

    var body: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(engaged ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground))
            .overlay(
                Image(systemName: "arrow.up.arrow.down")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged(handleChange)
                    .onEnded(handleEnd)
            )
    }

    private func handleChange(_ value: DragGesture.Value) {
        if startedAt == nil {
            startedAt = Date()
            travelled = 0
            pending = 0
            lastY = value.location.y
            if mode == .airMouse {
                air.setEngaged(true, target: .scroll)
            }
        }

        let dy = value.location.y - lastY
        lastY = value.location.y
        travelled += abs(dy)

        // Air Mouse scrolls by tilting, so finger travel here is only used to
        // tell a tap from a hold.
        guard mode == .trackpad else { return }

        // Withhold scrolling while the touch could still turn out to be a tap,
        // or a right click would scroll the page slightly on its way out.
        pending += dy
        guard travelled >= tapSlop else { return }
        client.scroll(dx: 0, dy: pending)
        pending = 0
    }

    private func handleEnd(_ value: DragGesture.Value) {
        let duration = Date().timeIntervalSince(startedAt ?? Date())
        if mode == .airMouse {
            air.setEngaged(false)
        }
        if travelled < tapSlop && duration < GestureTiming.tapMaxDuration {
            client.click(.right)
        }
        startedAt = nil
        pending = 0
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
        surface.onEngageChanged = { engaged in air.setEngaged(engaged, target: .pointer) }
        surface.emitsTouchMotion = mode == .trackpad
        return surface
    }

    func updateUIView(_ uiView: TrackpadSurface, context: Context) {
        uiView.emitsTouchMotion = mode == .trackpad
    }
}
