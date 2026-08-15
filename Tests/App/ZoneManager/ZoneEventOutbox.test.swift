import Foundation
@testable import HomeAssistant
import XCTest

final class ZoneEventOutboxTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ZoneEventOutboxTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testEventSurvivesOutboxRecreationUntilRemoved() throws {
        let event = try PendingZoneEvent(
            serverIdentifier: "server-id",
            eventType: "ios.zone_entered",
            eventData: ["zone": "zone.postfach"],
            isBeacon: true
        )
        var outbox: UserDefaultsZoneEventOutbox? = UserDefaultsZoneEventOutbox(
            defaults: defaults,
            key: "outbox"
        )
        outbox?.append(event)

        outbox = UserDefaultsZoneEventOutbox(defaults: defaults, key: "outbox")
        XCTAssertEqual(outbox?.pendingEvents, [event])
        XCTAssertEqual(outbox?.pendingEvents.first?.decodedEventData?["zone"] as? String, "zone.postfach")
        XCTAssertEqual(outbox?.pendingEvents.first?.isBeacon, true)

        outbox?.remove(id: event.id)
        XCTAssertTrue(outbox?.pendingEvents.isEmpty == true)
    }

    func testAppendingSameEventTwiceDoesNotDuplicateIt() throws {
        let event = try PendingZoneEvent(
            serverIdentifier: "server-id",
            eventType: "ios.zone_exited",
            eventData: ["zone": "zone.postfach"]
        )
        let outbox = UserDefaultsZoneEventOutbox(defaults: defaults, key: "outbox")

        outbox.append(event)
        outbox.append(event)

        XCTAssertEqual(outbox.pendingEvents, [event])
    }
}
