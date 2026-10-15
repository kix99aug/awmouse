import Foundation
import Testing

@testable import WatchBridge

/// The watch writes the host's JSON by hand, so these pin it to what
/// host/internal/proto reads. A typo here is a watch that connects, shows
/// green, and moves nothing.
@Suite("Host protocol")
struct WatchEventTests {
    private func decode(_ line: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try #require(object as? [String: Any])
    }

    @Test func everyMessageIsValidJSON() throws {
        let events: [WatchEvent] = [
            .move(dx: 12.5, dy: -4, dt: 33),
            .move(dx: 0.00001, dy: 1e9, dt: 0),
            .scroll(dx: 0, dy: 3),
            .click(.left), .click(.right), .click(.middle),
            .button(.left, down: true), .button(.left, down: false),
        ]
        for event in events {
            for line in event.messages {
                _ = try decode(line)
            }
        }
    }

    @Test func moveCarriesTheDeltaAndInterval() throws {
        let m = try decode(WatchEvent.move(dx: 12.5, dy: -4, dt: 33).messages[0])
        #expect(m["t"] as? String == "m")
        #expect(m["dx"] as? Double == 12.5)
        #expect(m["dy"] as? Double == -4)
        #expect(m["dt"] as? Double == 33)
    }

    @Test func scrollIsItsOwnKind() throws {
        let m = try decode(WatchEvent.scroll(dx: 0, dy: 3).messages[0])
        #expect(m["t"] as? String == "s")
        #expect(m["dy"] as? Double == 3)
    }

    /// The host counts clicks from presses and releases, so a click must be
    /// both, in that order.
    @Test func clickIsAPressThenARelease() throws {
        let lines = WatchEvent.click(.right).messages
        #expect(lines.count == 2)
        let press = try decode(lines[0])
        let release = try decode(lines[1])
        #expect(press["t"] as? String == "c")
        #expect(press["b"] as? String == "r")
        #expect(press["d"] as? Bool == true)
        #expect(release["b"] as? String == "r")
        #expect(release["d"] == nil, "the host reads a missing d as a release")
    }

    @Test func dragHalvesAreSingleMessages() throws {
        #expect(try decode(WatchEvent.button(.left, down: true).messages[0])["d"] as? Bool == true)
        #expect(try decode(WatchEvent.button(.left, down: false).messages[0])["d"] == nil)
    }

    @Test func onlyMotionMerges() {
        #expect(WatchEvent.move(dx: 1, dy: 2, dt: 8).merged(with: .move(dx: 3, dy: 4, dt: 8))
                == .move(dx: 4, dy: 6, dt: 16))
        #expect(WatchEvent.scroll(dx: 0, dy: 1).merged(with: .scroll(dx: 0, dy: 2))
                == .scroll(dx: 0, dy: 3))
        #expect(WatchEvent.move(dx: 1, dy: 1, dt: 8).merged(with: .scroll(dx: 0, dy: 1)) == nil)
        #expect(WatchEvent.click(.left).merged(with: .click(.left)) == nil,
                "two clicks are a double click, not one click")
    }
}

@Suite("Host credentials")
struct HostCredentialsTests {
    @Test func credentialsSurviveTheRoundTrip() {
        let sent = HostCredentials(address: "tc:abc123", key: "privkey:deadbeef", name: "iMac")
        #expect(HostCredentials(payload: sent.payload) == sent)
    }

    /// The Keychain copy is JSON; a field renamed without a migration would
    /// strand every watch that had stored the old shape.
    @Test func storedFormSurvivesTheRoundTrip() throws {
        let sent = HostCredentials(address: "tc:abc123", key: "privkey:deadbeef", name: "iMac")
        let data = try JSONEncoder().encode(sent)
        #expect(try JSONDecoder().decode(HostCredentials.self, from: data) == sent)
    }

    /// Everything in the payload must be a property-list type, or
    /// WatchConnectivity rejects it at runtime.
    @Test func payloadIsPropertyListSafe() {
        let c = HostCredentials(address: "tc:abc", key: "k", name: "iMac")
        #expect(PropertyListSerialization.propertyList(c.payload, isValidFor: .binary))
    }

    /// An address is the whole credential; without one there is nothing to
    /// dial, and an empty reply — the phone knowing no computer — must not
    /// look like a usable one.
    @Test func anEmptyAddressIsNotCredentials() {
        #expect(HostCredentials(payload: [:]) == nil)
        #expect(HostCredentials(payload: ["c.addr": "", "c.key": "k"]) == nil)
    }
}
