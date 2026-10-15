import SwiftUI
import UIKit
import WatchBridge

/// Exists for one line: `didFinishLaunchingWithOptions` is the only hook that
/// runs on a background launch, which is how the phone app starts when the
/// watch asks it for credentials. SwiftUI's scene has not appeared at that point
/// and may never appear at all.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated { AppCore.shared.start() }
        return true
    }
}

@main
struct AWMouseApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    @StateObject private var client = AppCore.shared.client
    @StateObject private var air = AppCore.shared.air
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                .environmentObject(air)
                .onOpenURL(perform: handlePairingLink)
                // Opened from the watch's Handoff offer, because the watch has
                // no credentials and needs the app running to get them. Being
                // open is the whole answer: the watch link has already
                // published them on launch. The phone does not connect to the
                // computer for the watch — the watch dials it itself.
                .onContinueUserActivity(controlActivityType) { _ in }
                .onChange(of: scenePhase) { _, phase in
                    // Coming back to the app is when to notice the tunnel died
                    // while it was suspended.
                    if phase == .active { client.reconnectIfNeeded() }
                }
        }
    }

    /// Handles `awmouse://pair?tc=…`, which is what the QR code on the
    /// computer encodes. Using a deep link rather than a bare address means the
    /// stock Camera app can open the app directly.
    private func handlePairingLink(_ url: URL) {
        guard let target = Target(pairingLink: url) else { return }
        client.connect(to: target)
    }
}

struct RootView: View {
    @EnvironmentObject private var client: Client

    var body: some View {
        switch client.state {
        case .connected:
            TrackpadView()
        default:
            ConnectView()
        }
    }
}
