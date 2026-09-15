import SwiftUI

@main
struct AWMouseApp: App {
    @StateObject private var client: Client
    @StateObject private var air: AirMouse

    init() {
        let client = Client()
        _client = StateObject(wrappedValue: client)
        _air = StateObject(wrappedValue: AirMouse(client: client))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                .environmentObject(air)
                .onOpenURL(perform: handlePairingLink)
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
