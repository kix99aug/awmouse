import Foundation

/// A short log of the phone's side of the watch relay.
///
/// What goes wrong in the relay happens while the phone is in a pocket: iOS
/// suspends the app, the watch wakes it, the tunnel may or may not have
/// survived. None of that is visible from the watch, which can only say that
/// the cursor stopped. This keeps the order of events in the app's Documents
/// folder, where `devicectl device copy from` can fetch it.
///
/// Small on purpose: lifecycle, state changes, gaps, and counts — never one
/// line per cursor movement.
enum RelayLog {
    private static let url = URL.documentsDirectory.appending(path: "relay.log")
    private static let previous = URL.documentsDirectory.appending(path: "relay.old.log")
    private static let cap = 256 * 1024
    private static let queue = DispatchQueue(label: "awmouse.relaylog")

    /// Waits until everything noted has reached the file. For the moment
    /// before the app ends itself, when an asynchronous write would be lost.
    static func flush() {
        queue.sync {}
    }

    static func note(_ text: String) {
        let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
        let line = Data("\(stamp) \(text)\n".utf8)
        queue.async {
            let files = FileManager.default
            // Rotated once, so the tail of a long run is always kept.
            if let size = try? files.attributesOfItem(atPath: url.path)[.size] as? Int, size > cap {
                try? files.removeItem(at: previous)
                try? files.moveItem(at: url, to: previous)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            } else {
                try? line.write(to: url)
            }
        }
    }
}
