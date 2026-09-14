import Foundation

@MainActor
final class Client: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var state: State = .disconnected
    @Published var lastURL: String = UserDefaults.standard.string(forKey: "lastURL") ?? ""

    private var task: URLSessionWebSocketTask?
    private let encoder = JSONEncoder()

    // Motion coalescing. While a send is in flight, further deltas accumulate
    // into a single pending sample instead of queueing behind it: a backlog of
    // stale deltas makes the cursor rubber-band. Button events deliberately
    // bypass this and are never dropped or merged.
    private var inflight = false
    private var moveDX = 0.0, moveDY = 0.0, moveDT = 0.0
    private var scrollDX = 0.0, scrollDY = 0.0

    // MARK: - Connection

    func connect(to url: URL) {
        disconnect()
        state = .connecting

        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()

        // A websocket task reports failure only on first I/O, so ping to find
        // out whether we actually reached anything.
        t.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                if let error {
                    self.state = .failed(error.localizedDescription)
                } else {
                    self.state = .connected
                    self.lastURL = url.absoluteString
                    UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")
                }
            }
        }

        receiveLoop(on: t)
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        inflight = false
        moveDX = 0; moveDY = 0; moveDT = 0
        scrollDX = 0; scrollDY = 0
        state = .disconnected
    }

    /// The host sends nothing, but the receive loop is what surfaces a dropped
    /// or refused connection.
    private func receiveLoop(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                switch result {
                case .success:
                    self.receiveLoop(on: t)
                case .failure(let error):
                    self.state = .failed(error.localizedDescription)
                    self.task = nil
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
        guard let task, let data = try? encoder.encode(msg),
              let json = String(data: data, encoding: .utf8)
        else {
            done?()
            return
        }

        task.send(.string(json)) { [weak self] error in
            Task { @MainActor in
                if let error, let self {
                    self.state = .failed(error.localizedDescription)
                }
                done?()
            }
        }
    }
}
