import Foundation

/// The objects that outlive any view, in one place so that both SwiftUI and
/// the app delegate can reach the same instances.
///
/// The watch link is why this exists. When the watch asks for credentials and
/// the phone app is not running, iOS launches it in the background to deliver
/// the request, and a background launch draws nothing — so anything set up
/// from a view's `onAppear` is not set up at all, and the request arrives at a
/// session with no delegate. The link has to be live from launch, which means
/// from somewhere that is not a view.
@MainActor
final class AppCore {
    static let shared = AppCore()

    let client = Client()
    lazy var air = AirMouse(client: client)
    lazy var watch = WatchLink(client: client)

    private init() {}

    /// Called from the app delegate, on every launch including the silent
    /// ones.
    func start() {
        watch.activate()
    }
}
