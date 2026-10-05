import SwiftUI

@main
struct WatchApp: App {
    @StateObject private var controller = WatchController()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(controller)
                .onAppear { controller.activate() }
        }
    }
}
