import SwiftUI
import WatchBridge

struct WatchRootView: View {
    @EnvironmentObject private var controller: WatchController

    /// The crown reports an accumulating position, so scrolling is the change
    /// in it. A detent is roughly one unit; the controller scales it.
    @State private var crown = 0.0
    @State private var lastCrown = 0.0

    /// The crown reports nothing unless a focusable view actually holds focus.
    /// Relying on it being granted implicitly is what produces "Crown
    /// Sequencer was set up without a view property" and a crown that silently
    /// does nothing.
    @FocusState private var crownFocused: Bool

    var body: some View {
        // The pad is the whole screen. Everything else is drawn on top of it
        // rather than beside it: this display is small enough that a status
        // line costing a row of pixels costs a usable fraction of the surface
        // the finger has to work with.
        TrackpadPad(controller: controller)
            .ignoresSafeArea(edges: [.horizontal, .bottom])
            // Not hit testable: a finger landing on the readout is still a
            // finger on the trackpad, and without this the status becomes a
            // dead strip across the one surface the app has.
            .overlay(alignment: .top) {
                status.padding(.horizontal, 6).allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                hint.padding(.bottom, 4).allowsHitTesting(false)
            }
            // Advertised only while the phone is not there. iOS will not
            // relaunch an app the user swiped out of the switcher, so this is
            // the one sanctioned way to put it within reach: the phone shows awmouse on
            // its lock screen, and a tap opens it.
            .userActivity(controlActivityType, isActive: !controller.reachable) { activity in
                activity.title = "awmouse"
                activity.isEligibleForHandoff = true
            }
            .focusable(true)
            .focused($crownFocused)
            .onAppear { crownFocused = true }
            .digitalCrownRotation(
                $crown, from: -10_000, through: 10_000, by: 1,
                sensitivity: .medium, isContinuous: true, isHapticFeedbackEnabled: true
            )
            .onChange(of: crown) { _, new in
                let delta = new - lastCrown
                lastCrown = new
                controller.crownScrolled(by: delta)
            }
    }

    /// Drawn over the pad, so it must never take a touch away from it.
    @ViewBuilder private var status: some View {
        // The watch's own tunnel outranks everything else: when it is up, the
        // phone's state says nothing about whether the cursor will move.
        if controller.direct {
            dot(.green, controller.host?.name.isEmpty == false ? controller.host!.name : "ready")
        } else if let note = controller.linkNote {
            // The watch is trying, or has tried and failed. Either way that
            // outranks what the phone is doing: this is the route that works
            // without it.
            dot(note == "connecting" ? .yellow : .orange, note)
        } else if !controller.reachable {
            dot(.orange, "open awmouse on iPhone")
        } else if let host = controller.host {
            if host.connected {
                dot(.green, host.name.isEmpty ? "ready" : host.name)
            } else {
                dot(.orange, "no computer")
            }
        } else {
            // Reachable, but the phone has never said anything. Different from
            // a phone connected to nothing, and worth telling apart: this one
            // is the link, that one is the computer.
            dot(.yellow, "waiting")
        }
    }

    private func dot(_ colour: Color, _ text: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(colour).frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder private var hint: some View {
        if let action = controller.lastAction {
            Text(action)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }

        // Only once there is something to say. A link that is keeping up
        // should not spend the small screen reporting that it is.
        if controller.dropped > 0 {
            Text("\(controller.dropped) dropped")
                .font(.system(size: 10))
                .foregroundStyle(Color.orange)
        }
    }
}
