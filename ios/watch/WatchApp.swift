import SwiftUI
import WatchBridge

@main
struct WatchApp: App {
    @StateObject private var controller = WatchController()

    init() {
        BridgeLog.setSink { FileLog.bridge.note($0) }
        FileLog.bridge.note("launch")
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(controller)
                .onAppear { controller.activate() }
        }
    }
}

extension FileLog {
    /// The watch's side of the link.
    static let bridge = FileLog(name: "bridge")
}
