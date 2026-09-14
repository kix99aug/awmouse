import SwiftUI

@main
struct AWMouseApp: App {
    @StateObject private var client = Client()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                .onOpenURL(perform: handlePairingLink)
        }
    }

    /// Handles `awmouse://pair?ws=ws://host:port/ws`, which is what the QR code
    /// on the computer encodes. Using a deep link rather than a bare address
    /// means the stock Camera app can open the app directly.
    private func handlePairingLink(_ url: URL) {
        guard url.scheme == "awmouse",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "ws" })?.value,
              let target = URL(string: value)
        else { return }

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
