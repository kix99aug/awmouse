import SwiftUI
import WatchBridge

@main
struct WatchApp: App {
    @StateObject private var controller = WatchController()

    init() {
        BridgeLog.setSink { WatchLog.note($0) }
        WatchLog.note("launch")
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(controller)
                .onAppear { controller.activate() }
        }
    }
}
