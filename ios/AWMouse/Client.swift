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

    // Move coalescing. While a send is in flight, further deltas accumulate
    // into a single pending sample instead of queueing behind it: a backlog of
    // stale deltas makes the cursor rubber-band. Clicks deliberately bypass
    // this and are never dropped or merged.
    private var inflight = false
    private var pendingDX = 0.0
    private var pendingDY = 0.0
    private var pendingDT = 0.0

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
        pendingDX = 0; pendingDY = 0; pendingDT = 0
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
        pendingDX += dx
        pendingDY += dy
        pendingDT += dt
        flushMove()
    }

    func click(_ button: MouseButton) {
        send(.button(button, down: true))
        send(.button(button, down: false))
    }

    func button(_ button: MouseButton, down: Bool) {
        send(.button(button, down: down))
    }

    private func flushMove() {
        guard !inflight, pendingDX != 0 || pendingDY != 0 else { return }

        let msg = Msg.move(dx: pendingDX, dy: pendingDY, dt: pendingDT)
        pendingDX = 0; pendingDY = 0; pendingDT = 0
        inflight = true

        send(msg) { [weak self] in
            guard let self else { return }
            self.inflight = false
            self.flushMove()
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
