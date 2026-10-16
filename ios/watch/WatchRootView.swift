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

    @State private var showingSettings = false

    /// Active only with the screen awake and the app in front. Wrist down,
    /// the watch keeps the app on screen but stops running it normally, which
    /// the controller must not mistake for the phone going quiet.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // A navigation stack for one thing: it is what gives a watch app the
        // toolbar slot in the top corner beside the clock, which is otherwise
        // dead space, and that is where settings live — on every screen, since
        // speed can be set and another computer picked whatever the state.
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showingSettings = true } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                .sheet(isPresented: $showingSettings) {
                    SettingsView().environmentObject(controller)
                }
        }
        // Advertised whenever the phone app is out of reach, not only once
        // the full-screen notice is up: the sooner the phone offers awmouse on
        // its lock screen, the sooner it is one tap away. iOS will not
        // relaunch an app the user swiped out of the switcher, and this is
        // the one sanctioned way to put it within reach.
        .userActivity(controlActivityType, isActive: !controller.reachable) { activity in
            activity.title = "awmouse"
            activity.isEligibleForHandoff = true
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            controller.setActive(phase == .active)
        }
    }

    /// The trackpad only when it will work. Anything else takes the whole
    /// screen: a small status line over a trackpad invites the finger to try
    /// it, and a gesture that goes nowhere is worse than one that is not
    /// offered.
    @ViewBuilder private var content: some View {
        if controller.canReachCursor {
            pad
        } else {
            StateScreen(state: screenState)
        }
    }

    private var pad: some View {
        // The pad is the whole screen. The one line drawn over it says which
        // computer it drives, and takes no touches: a finger landing on it is
        // still a finger on the trackpad.
        TrackpadPad(controller: controller)
            .ignoresSafeArea(edges: [.horizontal, .bottom])
            .overlay(alignment: .top) {
                connectedLine.padding(.horizontal, 6).allowsHitTesting(false)
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

    private var connectedLine: some View {
        HStack(spacing: 3) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(Color.green)
            Text(controller.status?.current.map(Self.label) ?? "connected")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// Every state but working, in the order that matters: the phone first,
    /// because the watch reaches the computer only through the phone app, so
    /// a missing phone outranks anything it last said.
    private var screenState: StateScreen.State {
        let name = controller.status?.current.map(Self.label)

        if controller.phoneMissing {
            return .init(symbol: "iphone", colour: .orange, busy: true,
                         title: "Open awmouse\non your iPhone",
                         detail: "Your watch reaches the computer through it. It's on your iPhone's lock screen.")
        }
        if !controller.reachable {
            // Unanswered, but not for long enough to give up: the watch is
            // asking for the phone app.
            return .init(symbol: "iphone", colour: .yellow, busy: true,
                         title: "Waking iPhone", detail: nil)
        }
        if !controller.confirmed {
            // Awake again after a long sleep: what the phone said before is
            // stale, and it is starting afresh.
            return .init(symbol: "arrow.triangle.2.circlepath", colour: .yellow, busy: true,
                         title: "Reconnecting", detail: name)
        }
        guard let status = controller.status else {
            return .init(symbol: "iphone", colour: .yellow, busy: true,
                         title: "Waiting for iPhone", detail: nil)
        }
        switch status.phase {
        case .connected:
            // Connected but not drivable cannot happen today; said plainly
            // rather than drawn as a trackpad that does nothing.
            return .init(symbol: "desktopcomputer", colour: .yellow, busy: true,
                         title: "Connecting", detail: name)
        case .connecting:
            let again = status.note == "reconnecting"
            return .init(symbol: again ? "arrow.triangle.2.circlepath" : "desktopcomputer",
                         colour: .yellow, busy: true,
                         title: again ? "Reconnecting" : "Connecting", detail: name)
        case .idle:
            if status.computers.isEmpty {
                return .init(symbol: "qrcode", colour: .orange, busy: false,
                             title: "Pair a computer",
                             detail: "Scan the code on your computer with awmouse on iPhone.")
            }
            let target = status.current ?? status.computers.first
            let rescan = status.note == "scan the code on iPhone"
            return .init(symbol: "desktopcomputer", colour: .orange, busy: false,
                         title: name ?? "Not connected",
                         detail: status.note ?? "Not connected.",
                         // A computer that wants its code scanned again can
                         // only be fixed on the phone; anything else, the watch
                         // can ask to try again.
                         action: rescan ? nil : target.map { computer in
                             .init(label: "Connect") { controller.choose(computer) }
                         })
        }
    }

    static func label(_ computer: KnownComputer) -> String {
        computer.name.isEmpty ? "computer" : computer.name
    }
}

/// One state, taking the whole screen: a symbol, what is happening, and what
/// if anything to do about it.
private struct StateScreen: View {
    struct Action {
        let label: String
        let run: () -> Void
    }

    struct State {
        var symbol: String
        var colour: Color
        /// Pulses the symbol, for states on their way somewhere. A symbol
        /// effect rather than a hand-rolled repeating animation: the system
        /// starts and stops it with `isActive`, where a `repeatForever`
        /// animation keyed on state is notorious for not stopping.
        var busy: Bool
        var title: String
        var detail: String?
        var action: Action?
    }

    let state: State

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: state.symbol)
                .font(.system(size: 34))
                .foregroundStyle(state.colour)
                .symbolEffect(.pulse, options: .repeating, isActive: state.busy)
            Text(state.title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let detail = state.detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let action = state.action {
                Button(action.label, action: action.run)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The watch's settings, on one page: how fast the cursor follows the finger,
/// and which of the phone's computers it drives.
private struct SettingsView: View {
    @EnvironmentObject private var controller: WatchController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Two buttons rather than a Stepper. A watchOS Stepper
                    // takes the crown when it has focus, and in a list the
                    // crown is what scrolls — the two fought.
                    HStack(spacing: 0) {
                        speedButton("minus", by: -1,
                                    disabled: controller.speed <= WatchController.speedRange.lowerBound)
                        Spacer(minLength: 4)
                        Text(controller.speed, format: .number.precision(.fractionLength(0...1)))
                            .font(.system(size: 17, weight: .semibold).monospacedDigit())
                            + Text("×").font(.system(size: 14))
                        Spacer(minLength: 4)
                        speedButton("plus", by: +1,
                                    disabled: controller.speed >= WatchController.speedRange.upperBound)
                    }
                    .lineLimit(1)
                } header: {
                    Text("Cursor speed")
                } footer: {
                    Text("On top of the computer's acceleration.")
                }

                Section("Computer") {
                    let computers = controller.status?.computers ?? []
                    if computers.isEmpty {
                        Text(controller.reachable ? "Pair a computer on iPhone" : "Waiting for iPhone")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(computers) { computer in
                        Button {
                            controller.choose(computer)
                            dismiss()
                        } label: {
                            HStack {
                                Text(WatchRootView.label(computer))
                                    .lineLimit(1)
                                Spacer()
                                if computer.id == controller.status?.current?.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    /// Plain-styled, so that each is its own target: two default buttons in
    /// one list row make the whole row one button.
    private func speedButton(_ symbol: String, by steps: Int, disabled: Bool) -> some View {
        Button { controller.stepSpeed(by: steps) } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 36, height: 30)
                .background(Circle().fill(Color.gray.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }
}
