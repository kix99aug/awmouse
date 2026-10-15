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

        // Every computer the phone knows, most recent first: the watch
        // offers them as a choice and defaults to the first, the same one the
        // phone's connect screen picks. Connecting moves a computer to the
        // front, so the default follows the phone.
        client.$hosts
            .removeDuplicates()
            .sink { [weak self] hosts in self?.publish(hosts) }
            .store(in: &watching)
    }

    private func publish(_ hosts: [KnownHost]) {
        guard !hosts.isEmpty else { return publisher.publish(nil) }
        publisher.publish(HostCredentials(
            key: ClientIdentity.key,
            computers: hosts.map { KnownComputer(address: $0.address, name: $0.name) }))
    }
}
