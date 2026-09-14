import SwiftUI

struct TrackpadView: View {
    @EnvironmentObject private var client: Client

    @State private var lastTranslation: CGSize = .zero
    @State private var lastSampleAt: Date?
    @State private var gestureStartedAt: Date?
    @State private var pendingTap: Task<Void, Never>?

    /// A tap is a touch that neither travelled far nor lingered.
    private let tapSlop: CGFloat = 10
    private let tapMaxDuration: TimeInterval = 0.25

    /// The cost of the single/double-tap convention: every left click waits
    /// this long to learn whether a second tap is coming. Switching to
    /// one-finger/two-finger would remove the delay entirely.
    private let doubleTapWindow: Duration = .milliseconds(300)

    var body: some View {
        VStack(spacing: 0) {
            surface
            hint
        }
        .background(Color(.systemBackground))
    }

    private var surface: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(Color(.secondarySystemBackground))
            .overlay(
                Text("trackpad")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            )
            .padding(12)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged(handleChange)
                    .onEnded(handleEnd)
            )
    }

    private var hint: some View {
        VStack(spacing: 4) {
            Text("tap = left click   ·   double tap = right click")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Disconnect") { client.disconnect() }
                .font(.caption)
        }
        .padding(.bottom, 12)
    }

    // MARK: - Gesture handling

    private func handleChange(_ value: DragGesture.Value) {
        let now = Date()

        if gestureStartedAt == nil {
            gestureStartedAt = now
            lastTranslation = .zero
            lastSampleAt = now
        }

        // DragGesture reports cumulative translation; the wire protocol wants
        // per-sample deltas.
        let dx = value.translation.width - lastTranslation.width
        let dy = value.translation.height - lastTranslation.height
        lastTranslation = value.translation

        let dt = now.timeIntervalSince(lastSampleAt ?? now) * 1000
        lastSampleAt = now

        guard dx != 0 || dy != 0 else { return }
        client.move(dx: Double(dx), dy: Double(dy), dt: dt)
    }

    private func handleEnd(_ value: DragGesture.Value) {
        let startedAt = gestureStartedAt ?? Date()
        gestureStartedAt = nil
        lastTranslation = .zero
        lastSampleAt = nil

        let travelled = hypot(value.translation.width, value.translation.height)
        let duration = Date().timeIntervalSince(startedAt)

        if travelled < tapSlop && duration < tapMaxDuration {
            handleTap()
        }
    }

    private func handleTap() {
        // A tap arriving while one is already pending makes the pair a
        // double tap, so the pending left click is cancelled.
        if let pending = pendingTap {
            pending.cancel()
            pendingTap = nil
            client.click(.right)
            return
        }

        pendingTap = Task { @MainActor in
            try? await Task.sleep(for: doubleTapWindow)
            guard !Task.isCancelled else { return }
            client.click(.left)
            pendingTap = nil
        }
    }
}
