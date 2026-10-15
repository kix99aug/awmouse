import Foundation

/// Where the watch link reports what WatchConnectivity is doing.
///
/// Each app points this at its own log file. The link breaks in a way that
/// survives restarting either app alone, and the only way to tell which side
/// stopped is to have both sides say what their session thought was
/// happening when it did.
public enum BridgeLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sink: (@Sendable (String) -> Void)?

    public static func setSink(_ newSink: (@Sendable (String) -> Void)?) {
        lock.withLock { sink = newSink }
    }

    static func note(_ text: String) {
        let current = lock.withLock { sink }
        current?(text)
    }
}
