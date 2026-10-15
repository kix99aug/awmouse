import Foundation
import Testing

@testable import WatchBridge

/// The one failure this protocol has actually had is a field name drifting
/// between two copies of it. One type now serves both sides, and these pin
/// what goes over the wire so a rename cannot pass unnoticed.
@Suite("Watch events")
struct WatchEventTests {
    private let events: [WatchEvent] = [
        .move(dx: 12.5, dy: -4, dt: 33),
        .scroll(dx: 0, dy: 3),
        .click(.left), .click(.right), .click(.middle),
        .button(.left, down: true), .button(.left, down: false),
    ]

    @Test func eventsSurviveTheRoundTrip() {
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

    /// WatchConnectivity will carry anything property-list shaped, including
    /// a message from a version that knows something this one does not.
    @Test func unknownPayloadsAreRejectedRatherThanGuessed() {
        #expect(WatchEvent(payload: [:]) == nil)
        #expect(WatchEvent(payload: ["t": "zzz"]) == nil)
        #expect(WatchEvent(payload: ["t": "c", "b": "x"]) == nil, "unknown button")
        #expect(WatchEvent(payload: ["t": "m", "dx": 1.0]) == nil, "incomplete move")
        #expect(WatchEvent(payload: ["t": "b", "b": "l"]) == nil, "press without direction")
    }

    /// Everything in the payload must be a property-list type, or
    /// WCSession.sendMessage rejects the whole message at runtime.
    @Test func payloadsArePropertyListSafe() {
        for event in events {
            #expect(PropertyListSerialization.propertyList(event.payload, isValidFor: .binary),
                    "\(event) is not a valid property list")
        }
    }
}

@Suite("Phone status")
struct PhoneStatusTests {
    private let sample = PhoneStatus(
        phase: .connecting,
        current: KnownComputer(id: "tc:imac", name: "iMac"),
        computers: [KnownComputer(id: "tc:imac", name: "iMac"), KnownComputer(id: "tc:pc", name: "")],
        note: nil)

    @Test func statusSurvivesTheRoundTrip() {
        #expect(PhoneStatus(payload: sample.payload) == sample)
        let idle = PhoneStatus(phase: .idle, current: nil, computers: [], note: "scan again")
        #expect(PhoneStatus(payload: idle.payload) == idle)
    }

    /// Order is meaning: the first is the phone's most recent.
    @Test func orderIsKept() {
        #expect(PhoneStatus(payload: sample.payload)?.computers.map(\.id) == ["tc:imac", "tc:pc"])
    }

    @Test func payloadIsPropertyListSafe() {
        #expect(PropertyListSerialization.propertyList(sample.payload, isValidFor: .binary))
    }

    /// A context from an older phone, or none at all, must not read as a
    /// phone saying something.
    @Test func unknownShapesAreNotStatus() {
        #expect(PhoneStatus(payload: [:]) == nil)
        #expect(PhoneStatus(payload: ["p": "dancing"]) == nil)
        #expect(PhoneStatus(payload: ["connected": true, "name": "iMac"]) == nil, "the old HostState shape")
    }
}
