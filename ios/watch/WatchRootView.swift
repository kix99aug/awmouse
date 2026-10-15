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
        Group {
            if controller.phoneMissing {
                PhoneMissingView()
            } else {
                // A navigation stack for one thing: it is what gives a watch
                // app the toolbar slot in the top corner beside the clock,
                // which is otherwise dead space, and that is where settings
                // live.
                NavigationStack {
                    pad
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

    /// The phone first, then the computer: the watch reaches the computer
    /// only through the phone app, so a missing phone outranks anything it
    /// last said.
    @ViewBuilder private var status: some View {
        if !controller.reachable {
            // Out of reach, but not for long enough to give up: the watch is
            // waking it.
            dot(.yellow, "iPhone", detail: "waking", busy: true)
        } else if let status = controller.status {
            let name = status.current.map(Self.label)
            switch status.phase {
            case .connected:
                dot(.green, name ?? "connected")
            case .connecting:
                dot(.yellow, name ?? "computer", detail: "connecting", busy: true)
            case .idle:
                if status.computers.isEmpty {
                    dot(.orange, "pair a computer on iPhone")
                } else {
                    dot(.orange, name ?? "no computer", detail: status.note)
                }
            }
        } else {
            // The phone app is there and has not said anything yet.
            dot(.yellow, "iPhone", detail: "waiting", busy: true)
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
            // The name gives way to the state, not the other way round: the
            // state is what the user needs to read.
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

/// The whole screen, because there is nothing else the watch can do: every
/// gesture goes through the phone app, and it is not running.
///
/// It got here because the watch asked the phone to start the app and
/// nothing came back — which is what happens after the app has been swiped
/// out of the app switcher. iOS reads that as "stop running this" and will not
/// launch it again for anything until it is opened by hand. The watch is
/// advertising Handoff meanwhile, so the phone shows awmouse on its lock
/// screen and in the app switcher: one tap rather than a search.
private struct PhoneMissingView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone")
                .font(.system(size: 34))
                .foregroundStyle(Color.orange)
                .symbolEffect(.pulse, options: .repeating)
            Text("Open awmouse\non your iPhone")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Your watch reaches the computer through it. It's on your iPhone's lock screen.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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
                    // A stepper rather than a slider: each press is a step
                    // the hand can feel and count, and the crown turns it too.
                    Stepper(value: $controller.speed, in: WatchController.speedRange, step: 0.25) {
                        Text(controller.speed, format: .number.precision(.fractionLength(0...2)))
                            + Text("×")
                    }
                } header: {
                    Text("Cursor speed")
                } footer: {
                    Text("On top of the computer's acceleration. Faster flicks gain more.")
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
}
