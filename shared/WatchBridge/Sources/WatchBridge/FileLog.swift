import Foundation

/// A small log in the app's Documents folder, where
/// `devicectl device copy from` can fetch it off a phone or a watch.
///
/// What goes wrong in the watch link happens with the phone in a pocket and
/// the watch on a wrist, where nothing can be attached; each app keeps one of
/// these, and between them they say which side stopped talking, and how. Kept
/// small on purpose — lifecycle, state changes, gaps, counts, never a line per
/// cursor movement — and rotated once, so the tail of a long run survives.
public struct FileLog: Sendable {
    private let url: URL
    private let previous: URL
    private let queue: DispatchQueue
    private static let cap = 256 * 1024

    /// `name.log`, with `name.old.log` for what came before.
    public init(name: String) {
        url = URL.documentsDirectory.appending(path: "\(name).log")
        previous = URL.documentsDirectory.appending(path: "\(name).old.log")
        queue = DispatchQueue(label: "awmouse.log.\(name)")
    }

    public func note(_ text: String) {
        let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
        let line = Data("\(stamp) \(text)\n".utf8)
        let (url, previous) = (url, previous)
        queue.async {
            let files = FileManager.default
            if let size = try? files.attributesOfItem(atPath: url.path)[.size] as? Int, size > Self.cap {
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

    /// Waits until everything noted has reached the file. For the moment
    /// before an app ends itself, when a pending write would be lost.
    public func flush() {
        queue.sync {}
    }
}
