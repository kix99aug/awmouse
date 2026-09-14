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

            // No horizontal padding: both targets run to their screen edge, so
            // a thumb can find either without aiming. Only the inner corners
            // are rounded, since a rounded corner against the screen edge would
            // just be a gap you can still press.
            HStack(spacing: 8) {
                Trackpad(client: client, air: air, mode: mode)
                    .background(surfaceTint)
                    .clipShape(
                        .rect(
                            topLeadingRadius: 0,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 18,
                            topTrailingRadius: 18
                        )
                    )
                    .overlay(surfaceLabel)

                ScrollStrip(client: client, air: air, mode: mode)
                    .frame(width: 72)
            }
            .padding(.vertical, 12)

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
                row("double tap", "double click")
                row("double tap, hold", "drag to select")
                row("strip tap", "right click")
                row("strip double tap", "middle click")
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

/// The right-edge strip: tap for right click, double tap for middle click,
/// hold to scroll.
///
/// All three live here so the whole gesture set is reachable with one finger.
/// The multi-finger equivalents still work, but they are awkward when the same
/// hand is holding the phone, so none of them is required.
private struct ScrollStrip: UIViewRepresentable {
    let client: Client
    let air: AirMouse
    let mode: InputMode

    func makeUIView(context: Context) -> StripSurface {
        let surface = StripSurface()
        surface.backgroundColor = .secondarySystemBackground
        surface.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        surface.layer.cornerRadius = 18

        surface.onScroll = { dx, dy in client.scroll(dx: dx, dy: dy) }
        surface.onTap = { client.click(.right) }
        surface.onDoubleTap = { client.click(.middle) }
        surface.onEngageChanged = { engaged in
            surface.backgroundColor = engaged
                ? UIColor.tintColor.withAlphaComponent(0.18)
                : .secondarySystemBackground
            air.setEngaged(engaged, target: .scroll)
        }

        let label = UIImageView(image: UIImage(systemName: "arrow.up.arrow.down"))
        label.tintColor = .tertiaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
        ])

        surface.emitsTouchScroll = mode == .trackpad
        return surface
    }

    func updateUIView(_ uiView: StripSurface, context: Context) {
        uiView.emitsTouchScroll = mode == .trackpad
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
