import Combine
import Foundation
import WatchBridge

/// The phone's whole part in the watch: telling it which computer to dial and
/// with what identity.
///
/// The watch cannot learn either any other way — it has no camera, so it can
/// never scan a pairing code. Once it has them it keeps its own copy and
/// reaches the computer over its own tunnel; nothing it does passes through
/// here. That is deliberate. The phone used to relay the watch's events, and
/// a phone woken to relay would dial the computer itself, with the same
/// identity the watch was using, and the two connections fought.
@MainActor
final class WatchLink {
    private let publisher = CredentialPublisher()
    private unowned let client: Client
    private var watching: Set<AnyCancellable> = []

    init(client: Client) {
        self.client = client
    }

    func activate() {
        guard watching.isEmpty else { return }
        publisher.activate()

        // The most recently used computer, because that is the one the watch
        // should use — the same default the phone's connect screen picks.
        // Connecting moves a computer to the front, so this also follows the
        // phone when it switches to another.
        client.$hosts
            .map { $0.first }
            .removeDuplicates()
            .sink { [weak self] host in self?.publish(host) }
            .store(in: &watching)
    }

    private func publish(_ host: KnownHost?) {
        publisher.publish(host.map {
            HostCredentials(address: $0.address, key: ClientIdentity.key, name: $0.name)
        })
    }
}
