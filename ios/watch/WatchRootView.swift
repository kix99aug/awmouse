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

    @Environment(\.scenePhase) private var scenePhase

    @State private var picking = false

    private var needsPhone: Bool {
        switch controller.credentialPhase {
        case .ready: return false
        case .asking, .phoneUnavailable, .phoneHasNone: return true
        }
    }

    var body: some View {
        // A navigation stack for one thing: it is what gives a watch app the
        // toolbar slot in the top corner beside the clock, which is otherwise
        // dead space, and that is where choosing a computer lives.
        NavigationStack {
            pad
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if !controller.computers.isEmpty {
                            Button { picking = true } label: {
                                Image(systemName: "desktopcomputer")
                            }
                        }
                    }
                }
                .sheet(isPresented: $picking) {
                    ComputerPicker(
                        computers: controller.computers,
                        current: controller.current,
                        choose: controller.choose)
                }
        }
    }

    private var pad: some View {
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
            // Advertised only while the watch needs the phone app opened to
            // get credentials. iOS will not relaunch an app the user swiped
            // out of the switcher, so this is the one sanctioned way to put it
            // within reach: the phone shows awmouse on its lock screen, and a
            // tap opens it.
            .userActivity(controlActivityType, isActive: needsPhone) { activity in
                activity.title = "awmouse"
                activity.isEligibleForHandoff = true
            }
            .focusable(true)
            .focused($crownFocused)
            .onAppear { crownFocused = true }
            // Raised again after the user went to open the phone app: ask
            // once more rather than waiting for reachability to notice.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { controller.retryCredentials() }
            }
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
    ///
    /// Credentials first: without them there is nothing to dial, and what the
    /// user has to do about it — open the phone app — is the only thing worth
    /// saying.
    @ViewBuilder private var status: some View {
        switch controller.credentialPhase {
        case .asking:
            dot(.yellow, "asking iPhone", busy: true)
        case .phoneUnavailable:
            dot(.orange, "open awmouse on iPhone")
        case .phoneHasNone:
            dot(.orange, "pair a computer on iPhone")
        case .ready:
            // Always the computer's name, whatever the state: with more than
            // one to choose from, "connecting" alone does not say to what.
            let name = controller.current.map(Self.label) ?? "computer"
            if controller.connected {
                dot(.green, name)
            } else if let note = controller.linkNote, note != "connecting" {
                dot(.orange, name, detail: note)
            } else {
                dot(.yellow, name, detail: "connecting", busy: true)
            }
        }
    }

    static func label(_ computer: KnownComputer) -> String {
        computer.name.isEmpty ? "computer" : computer.name
    }

    /// `busy` pulses the light, for the states that are on their way
    /// somewhere: a steady light reads as settled, and "connecting" that sits
    /// still looks exactly like "connecting" that has hung.
    ///
    /// A symbol effect rather than a hand-rolled repeating animation. The
    /// system starts and stops it with `isActive`; a `repeatForever`
    /// animation keyed on view state is notorious for not stopping when the
    /// state moves on, which here would be a green light still flashing.
    private func dot(_ colour: Color, _ text: String, detail: String? = nil,
                     busy: Bool = false) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(colour)
                .symbolEffect(.pulse, options: .repeating, isActive: busy)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            // The name gives way to the state, not the other way round:
            // "no answer" is what the user needs to read.
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
    }

    @ViewBuilder private var hint: some View {
        if let action = controller.lastAction {
            Text(action)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

/// The phone's computers, one tap each. The current one is ticked.
private struct ComputerPicker: View {
    let computers: [KnownComputer]
    let current: KnownComputer?
    let choose: (KnownComputer) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(computers) { computer in
                Button {
                    choose(computer)
                    dismiss()
                } label: {
                    HStack {
                        Text(WatchRootView.label(computer))
                            .lineLimit(1)
                        Spacer()
                        if computer == current {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .navigationTitle("Computers")
        }
    }
}
