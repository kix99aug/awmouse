import Foundation
import UIKit

@MainActor
final class Client: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        /// The host did not know this phone and the code it sent was stale
        /// or spent. The QR is the only source of codes, so: scan again.
        case needsRescan
        case connected
        case failed(String)
    }

    @Published private(set) var state: State = .disconnected
    /// The computer this phone last connected to. Once paired, reconnecting
    /// needs no code, so the app can do it on launch without asking.
    @Published private(set) var lastTarget: Target? = UserDefaults.standard.string(forKey: "lastURL")
        .flatMap { Target(address: $0) }

    private var link: Link?
    private var pinger: Task<Void, Never>?
    private var dialGeneration = 0 // a dial that finishes after a newer connect() is discarded
    private let encoder = JSONEncoder()

    // Motion coalescing. While a send is in flight, further deltas accumulate
    // into a single pending sample instead of queueing behind it: a backlog of
    // stale deltas makes the cursor rubber-band. Button events deliberately
    // bypass this and are never dropped or merged.
    private var inflight = false
    private var moveDX = 0.0, moveDY = 0.0, moveDT = 0.0
    private var scrollDX = 0.0, scrollDY = 0.0

    // MARK: - Connection

    func connect(to target: Target) {
        disconnect()
        state = .connecting

        dialGeneration += 1
        let generation = dialGeneration
        Task { [weak self] in
            do {
                let l = try await TunnelLink.dial(
                    address: target.address, code: target.code, deviceName: UIDevice.current.name
                ) { [weak self] reason in
                    self?.failed("connection closed: " + reason)
                }
                // The user may have cancelled or retargeted while we were
                // dialing.
                guard let self, self.dialGeneration == generation,
                      case .connecting = self.state
                else { l.close(); return }
                self.link = l
                self.opened(target)
                self.startPinging(l)
            } catch PairingError.codeRequired {
                guard let self, self.dialGeneration == generation else { return }
                self.state = .needsRescan
            } catch {
                self?.failed(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        pinger?.cancel()
        pinger = nil
        link?.close()
        link = nil
        inflight = false
        moveDX = 0; moveDY = 0; moveDT = 0
        scrollDX = 0; scrollDY = 0
        state = .disconnected
    }

    private func opened(_ target: Target) {
        state = .connected
        // Remember the address only: the code was single-use.
        lastTarget = Target(address: target.address)
        UserDefaults.standard.set(target.address, forKey: "lastURL")
    }

    private func failed(_ message: String) {
        // Only a live attempt or connection can fail. Anything else — torn
        // down on purpose, or waiting for a code after the host closed the
        // refused connection — is a stale callback, and must not overwrite
        // the state that replaced it.
        switch state {
        case .connecting, .connected: break
        default: return
        }
        pinger?.cancel()
        pinger = nil
        link = nil
        state = .failed(message)
    }

    /// The tunnel cannot tell a dead host from a quiet one on its own — see
    /// `TunnelLink.ping` — so ask it every few seconds.
    private func startPinging(_ l: TunnelLink) {
        pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                do {
                    _ = try await l.ping()
                } catch {
                    self?.failed("host not responding")
                    return
                }
            }
        }
    }

    // MARK: - Input

    func move(dx: Double, dy: Double, dt: Double) {
        moveDX += dx
        moveDY += dy
        moveDT += dt
        flush()
    }

    func scroll(dx: Double, dy: Double) {
        scrollDX += dx
        scrollDY += dy
        flush()
    }

    func click(_ button: MouseButton) {
        send(.button(button, down: true))
        send(.button(button, down: false))
    }

    func button(_ button: MouseButton, down: Bool) {
        send(.button(button, down: down))
    }

    /// Move and scroll are mutually exclusive — the surface is in one mode at a
    /// time — so a single in-flight slot serves both.
    private func flush() {
        guard !inflight else { return }

        let msg: Msg
        if moveDX != 0 || moveDY != 0 {
            msg = .move(dx: moveDX, dy: moveDY, dt: moveDT)
            moveDX = 0; moveDY = 0; moveDT = 0
        } else if scrollDX != 0 || scrollDY != 0 {
            msg = .scroll(dx: scrollDX, dy: scrollDY)
            scrollDX = 0; scrollDY = 0
        } else {
            return
        }

        inflight = true
        send(msg) { [weak self] in
            guard let self else { return }
            self.inflight = false
            self.flush()
        }
    }

    private func send(_ msg: Msg, then done: (@MainActor () -> Void)? = nil) {
        guard let link, let data = try? encoder.encode(msg),
              let json = String(data: data, encoding: .utf8)
        else {
            done?()
            return
        }

        link.send(json) { [weak self] error in
            if let error { self?.failed(error.localizedDescription) }
            done?()
        }
    }
}
