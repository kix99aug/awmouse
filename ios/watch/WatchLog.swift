import Foundation

/// The watch's side of the link, kept in the app's Documents folder where
/// `devicectl device copy from` can fetch it. The phone keeps its own; between
/// them they say which side stopped talking, and with what error.
enum WatchLog {
    private static let url = URL.documentsDirectory.appending(path: "bridge.log")
    private static let previous = URL.documentsDirectory.appending(path: "bridge.old.log")
    private static let cap = 256 * 1024
    private static let queue = DispatchQueue(label: "awmouse.bridgelog")

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
