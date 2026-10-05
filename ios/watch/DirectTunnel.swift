import Foundation
import WatchBridge
#if canImport(Awmtunnel)
import Awmtunnel
#endif

/// The watch's own connection to the computer, skipping the phone.
///
/// This exists because the phone could not be relied on. iOS will not relaunch
/// an app the user swiped out of the switcher, so a watch that could only
/// speak through the phone was dead whenever the phone app had been dismissed
/// — which is most of the time, and exactly when someone reaches for the watch.
///
/// The tunnel is the same Go library the phone uses, retargeted to watchOS by
/// ios/tools/watchify.py. Go has no watchOS port; what makes this work is that
/// a modern watch is arm64, so the compiled code is already correct and only
/// its platform label was wrong. Watches older than that are arm64_32 and get
/// nothing here, so the phone relay stays as the fallback.
@MainActor
final class DirectTunnel: ObservableObject {
    enum State: Equatable {
        case idle          // nothing to dial with
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// True when this build can dial at all. False on a watch whose
    /// architecture the Go library does not cover.
    static var supported: Bool {
        #if canImport(Awmtunnel)
        return true
        #else
        return false
        #endif
    }

    #if canImport(Awmtunnel)
    private var session: AwmtunnelSession?
    #endif
    private var dialing = false

    /// Connects if there is something to connect to and nothing already in
    /// flight. Safe to call on every event: a stream of movements produces one
    /// dial, not one per movement.
    func connect(using credentials: HostCredentials?) {
        #if canImport(Awmtunnel)
        guard let credentials, !credentials.address.isEmpty else {
            state = .idle
            return
        }
        guard !dialing, session == nil else { return }
        dialing = true
        state = .connecting

        Task { [weak self] in
            let outcome = await Self.dial(credentials)
            guard let self else { return }
            self.dialing = false
            switch outcome {
            case .success(let session):
                self.session = session
                self.state = .connected
            case .failure(let error):
                self.state = .failed(Self.describe(error))
            }
        }
        #else
        state = .idle
        #endif
    }

    func disconnect() {
        #if canImport(Awmtunnel)
        let open = session
        session = nil
        state = .idle
        Task.detached { _ = try? open?.close() }
        #endif
    }

    /// Sends one event. Returns false when there is no tunnel, which is the
    /// caller's cue to fall back to the phone.
    @discardableResult
    func send(_ event: WatchEvent) -> Bool {
        #if canImport(Awmtunnel)
        guard case .connected = state, let session else { return false }
        let messages = event.messages
        Task.detached { [weak self] in
            do {
                for json in messages { try session.send(json) }
            } catch {
                // The tunnel is gone. Drop it rather than keep failing; the
                // next event dials again.
                await MainActor.run { self?.dropped() }
            }
        }
        return true
        #else
        return false
        #endif
    }

    #if canImport(Awmtunnel)
    private func dropped() {
        session = nil
        state = .failed("lost")
    }

    /// Off the main actor: dialling is a network round trip, and the watch's
    /// main thread is also drawing the trackpad the user is dragging on.
    private static func dial(
        _ credentials: HostCredentials
    ) async -> Result<AwmtunnelSession, Error> {
        await Task.detached {
            do {
                // Dial is a top-level Go function, so gomobile exposes it as a
                // C function and the NSError** stays an out-parameter rather
                // than becoming `throws`.
                var error: NSError?
                let session = AwmtunnelDial(credentials.address, credentials.key, 15_000, nil, &error)
                if let error { return .failure(error) }
                guard let session else { return .failure(TunnelError.noSession) }

                // The host admits a device it already knows whatever code it
                // sends, and the watch never has one — it cannot scan. If the
                // host has forgotten this key, this is where it says so.
                let result = try session.hello("", name: WKInterfaceDeviceName, timeoutMillis: 5_000)
                guard result.admitted else {
                    _ = try? session.close()
                    return .failure(TunnelError.refused(result.reason))
                }
                return .success(session)
            } catch {
                return .failure(error)
            }
        }.value
    }
    #endif

    private static func describe(_ error: Error) -> String {
        if case TunnelError.refused(let reason) = error {
            return reason.isEmpty ? "refused" : reason
        }
        return "offline"
    }

    enum TunnelError: LocalizedError, Equatable {
        case noSession
        case refused(String)
    }
}

/// The watch reports itself by name so the host's device list can tell it from
/// the phone that paired it.
private let WKInterfaceDeviceName = "Apple Watch"

private extension WatchEvent {
    /// The host speaks the same JSON to every client; the watch builds it
    /// directly rather than going through the phone's encoder, which lives in
    /// the phone target.
    ///
    /// A click is two messages, not one. The host counts clicks itself — that
    /// is how it tells a double click from two single ones — so it wants the
    /// press and the release, and a single message would never produce either.
    var messages: [String] {
        switch self {
        case .move(let dx, let dy, let dt):
            return [#"{"t":"m","dx":\#(dx),"dy":\#(dy),"dt":\#(dt)}"#]
        case .scroll(let dx, let dy):
            return [#"{"t":"s","dx":\#(dx),"dy":\#(dy)}"#]
        case .click(let button):
            return [#"{"t":"c","b":"\#(button.rawValue)","d":true}"#,
                    #"{"t":"c","b":"\#(button.rawValue)"}"#]
        }
    }
}
