import Foundation
import Testing

@testable import WatchBridge

/// The one failure this protocol has actually had is a field name drifting
/// between two copies of it. One type now serves both sides, and these pin
/// what goes over the wire so a rename cannot pass unnoticed.
@Test func eventsSurviveTheRoundTrip() {
    let events: [WatchEvent] = [
        .move(dx: 12.5, dy: -4, dt: 33),
        .scroll(dx: 0, dy: 3),
        .click(.left),
        .click(.right),
        .click(.middle),
    ]
    for event in events {
        #expect(WatchEvent(payload: event.payload) == event)
    }
}

@Test func payloadKeysMatchTheHostProtocol() {
    #expect(WatchEvent.move(dx: 1, dy: 2, dt: 3).payload["t"] as? String == "m")
    #expect(WatchEvent.scroll(dx: 1, dy: 2).payload["t"] as? String == "s")
    #expect(WatchEvent.click(.right).payload["t"] as? String == "c")
    #expect(WatchEvent.click(.right).payload["b"] as? String == "r")
}

/// WatchConnectivity will carry anything property-list shaped, including a
/// message from a version that knows something this one does not.
@Test func unknownPayloadsAreRejectedRatherThanGuessed() {
    #expect(WatchEvent(payload: [:]) == nil)
    #expect(WatchEvent(payload: ["t": "zzz"]) == nil)
    #expect(WatchEvent(payload: ["t": "c", "b": "x"]) == nil, "unknown button")
    #expect(WatchEvent(payload: ["t": "m", "dx": 1.0]) == nil, "incomplete move")
}

/// Everything in the payload must be a property-list type, or
/// WCSession.sendMessage rejects the whole message at runtime.
@Test func payloadsArePropertyListSafe() {
    for event: WatchEvent in [.move(dx: 1, dy: 2, dt: 3), .scroll(dx: 1, dy: 2), .click(.left)] {
        #expect(PropertyListSerialization.propertyList(event.payload, isValidFor: .binary),
                "\(event) is not a valid property list")
    }
}

@Suite("Host credentials")
struct HostCredentialsTests {
    @Test func credentialsSurviveTheRoundTrip() {
        let sent = HostCredentials(address: "tc:abc123", key: "privkey:deadbeef", name: "iMac")
        let got = HostCredentials(payload: sent.payload)
        #expect(got == sent)
    }

    /// They share one application context with HostState, so neither may read
    /// the other's keys as its own.
    @Test func credentialsAndStateDoNotCollide() {
        let state = HostState(connected: true, name: "iMac")
        let credentials = HostCredentials(address: "tc:abc", key: "k", name: "iMac")
        var context = state.payload
        context.merge(credentials.payload) { _, new in new }

        #expect(HostState(payload: context) == state)
        #expect(HostCredentials(payload: context) == credentials)
    }

    /// An address is the whole credential; without one there is nothing to
    /// dial, and a half-filled context must not look like a usable one.
    @Test func anEmptyAddressIsNotCredentials() {
        #expect(HostCredentials(payload: ["c.addr": "", "c.key": "k"]) == nil)
        #expect(HostCredentials(payload: HostState(connected: true, name: "x").payload) == nil)
    }
}
