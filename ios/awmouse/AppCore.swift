import Foundation
import UIKit
import WatchBridge

/// The objects that outlive any view, in one place so that both SwiftUI and
/// the app delegate can reach the same instances.
///
/// The watch link is why this exists. iOS wakes the phone app in the
/// background to deliver a request from the watch, and a background launch
/// draws nothing — so anything set up from a view's `onAppear` is not set up
/// at all, and the request arrives at a session with no delegate. The link
/// has to be live from launch, which means from somewhere that is not a view.
@MainActor
final class AppCore {
    static let shared = AppCore()

    let client = Client()
    lazy var air = AirMouse(client: client)
    lazy var watch = WatchRelay(client: client)

    private init() {}

    /// Called from the app delegate, on every launch including the silent
    /// ones.
    func start() {
        BridgeLog.setSink { RelayLog.note("wc: \($0)") }
        RelayLog.note("launch, \(UIApplication.shared.applicationState == .background ? "in background" : "in foreground")")
        for (name, label) in [
            (UIApplication.didEnterBackgroundNotification, "entered background"),
            (UIApplication.willEnterForegroundNotification, "entering foreground"),
            (UIApplication.willTerminateNotification, "terminating"),
        ] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                RelayLog.note(label)
                // The relay once went silent with the app in the foreground
                // and working; this is what the session thought at the time.
                MainActor.assumeIsolated {
                    RelayLog.note("wc state: \(AppCore.shared.watch.sessionState)")
                }
            }
        }
        watch.activate()
    }
}
