import CoreLocation
import Foundation
import GRDB
@testable import HomeAssistant
@testable import Shared
import XCTest

class ZoneManagerCollectorTests: XCTestCase {
    private var database: DatabaseQueue!
    private var previousDatabase: (() -> DatabaseQueue)!
    private var delegate: FakeZoneManagerCollectorDelegate!
    private var locationManager: FakeCLLocationManager!
    private var collector: ZoneManagerCollectorImpl!

    enum TestError: Error {
        case anyError
    }

    override func setUpWithError() throws {
        try super.setUpWithError()

        database = try DatabaseQueue()
        try AppZoneTable().createIfNeeded(database: database)
        previousDatabase = Current.database
        Current.database = { self.database }

        locationManager = FakeCLLocationManager()
        delegate = FakeZoneManagerCollectorDelegate()
        collector = ZoneManagerCollectorImpl()
        collector.delegate = delegate
    }

    override func tearDown() {
        Current.database = previousDatabase

        super.tearDown()
    }

    func testDidFailDoesLog() {
        collector.locationManager(locationManager, didFailWithError: TestError.anyError)
        XCTAssertEqual(delegate.states.count, 1)

        guard let state = delegate.states.first else {
            return
        }

        switch state {
        case .didError(TestError.anyError):
            // pass
            break
        default:
            XCTFail("expected error, got \(state)")
        }
    }

    func testDidFailMonitoringDoesLog() {
        let region = CLCircularRegion()
        collector.locationManager(locationManager, monitoringDidFailFor: region, withError: TestError.anyError)
        XCTAssertEqual(delegate.states.count, 1)

        guard let state = delegate.states.first else {
            return
        }

        switch state {
        case .didFailMonitoring(region, TestError.anyError):
            // pass
            break
        default:
            XCTFail("expected error, got \(state)")
        }
    }

    func testDidStartMonitoringLogsButDoesntRequestState() {
        let region = CLCircularRegion()
        collector.locationManager(locationManager, didStartMonitoringFor: region)
        XCTAssertEqual(delegate.states.count, 1)

        guard let state = delegate.states.first else {
            return
        }

        switch state {
        case .didStartMonitoring(region):
            // pass
            break
        default:
            XCTFail("expected start, got \(state)")
        }

        XCTAssertEqual(locationManager.requestedRegions, [])
    }

    func testDidDetermineStateWithNoZoneInDatabase() {
        let region = CLCircularRegion()
        collector.locationManager(locationManager, didDetermineState: .inside, for: region)
        XCTAssertEqual(delegate.events.count, 1)

        guard let event = delegate.events.first else {
            return
        }

        XCTAssertEqual(event.eventType, .region(region, .inside))
        XCTAssertNil(event.associatedZone)
    }

    func testDidDetermineStateWithZoneInDatabase() throws {
        let server = Server.fake()

        let region = CLCircularRegion(
            center: .init(latitude: 1.23, longitude: 4.56),
            radius: 20,
            identifier: AppZone.primaryKey(
                sourceIdentifier: "zone_identifier",
                serverIdentifier: server.identifier.rawValue
            )
        )
        let zone = AppZone(
            entityId: "zone_identifier",
            serverIdentifier: server.identifier.rawValue
        )

        try database.write { db in
            try zone.save(db)
        }

        collector.locationManager(locationManager, didDetermineState: .inside, for: region)
        XCTAssertEqual(delegate.events.count, 1)

        guard let event = delegate.events.first else {
            return
        }

        XCTAssertEqual(event.eventType, .region(region, .inside))
        XCTAssertEqual(event.associatedZone, zone)
    }

    func testDidDetermineStateWithZoneInDatabaseForSmallRegionSplitIntoMultiple() throws {
        let server = Server.fake()
        let region = CLCircularRegion(
            center: .init(latitude: 1.23, longitude: 4.56),
            radius: 20,
            identifier: AppZone.primaryKey(
                sourceIdentifier: "zone_identifier",
                serverIdentifier: server.identifier.rawValue
            ) + "@100"
        )
        let zone = AppZone(
            entityId: "zone_identifier",
            serverIdentifier: server.identifier.rawValue
        )

        try database.write { db in
            try zone.save(db)
        }

        collector.locationManager(locationManager, didDetermineState: .inside, for: region)
        XCTAssertEqual(delegate.events.count, 1)

        guard let event = delegate.events.first else {
            return
        }

        XCTAssertEqual(event.eventType, .region(region, .inside))
        XCTAssertEqual(event.associatedZone, zone)
    }

    func testBeaconEntryRequiresRangingConfirmation() {
        let region = CLBeaconRegion(uuid: UUID(), identifier: "beacon_region")

        collector.locationManager(locationManager, didDetermineState: .inside, for: region)

        XCTAssertTrue(delegate.events.isEmpty)
        XCTAssertEqual(locationManager.startedRangingConstraints, [region.beaconIdentityConstraint])
    }

    func testForegroundScanStartsRangingForBeaconOutsideZone() throws {
        let server = Server.fake()
        let zone = AppZone(
            entityId: "beacon_region",
            serverIdentifier: server.identifier.rawValue,
            inRegion: false
        )
        try database.write { db in
            try zone.save(db)
        }
        let region = CLBeaconRegion(uuid: UUID(), identifier: zone.identifier)

        collector.startForegroundBeaconScanning(in: [region], manager: locationManager)

        XCTAssertEqual(locationManager.startedRangingConstraints, [region.beaconIdentityConstraint])
    }

    func testForegroundScanKeepsRangingForBeaconAlreadyInsideZone() throws {
        let server = Server.fake()
        let zone = AppZone(
            entityId: "beacon_region",
            serverIdentifier: server.identifier.rawValue,
            inRegion: true
        )
        try database.write { db in
            try zone.save(db)
        }
        let region = CLBeaconRegion(uuid: UUID(), identifier: zone.identifier)

        collector.startForegroundBeaconScanning(in: [region], manager: locationManager)

        XCTAssertEqual(locationManager.startedRangingConstraints, [region.beaconIdentityConstraint])
    }

    func testForegroundScanIgnoresCircularRegions() {
        let region = CLCircularRegion(
            center: .init(latitude: 1, longitude: 2),
            radius: 20,
            identifier: "circular"
        )

        collector.startForegroundBeaconScanning(in: [region], manager: locationManager)

        XCTAssertTrue(locationManager.startedRangingConstraints.isEmpty)
    }

    func testForegroundScanStopsWhenAppResignsActive() throws {
        let server = Server.fake()
        let zone = AppZone(
            entityId: "beacon_region",
            serverIdentifier: server.identifier.rawValue,
            inRegion: false
        )
        try database.write { db in
            try zone.save(db)
        }
        let region = CLBeaconRegion(uuid: UUID(), identifier: zone.identifier)

        collector.startForegroundBeaconScanning(in: [region], manager: locationManager)
        collector.stopForegroundBeaconScanning(manager: locationManager)

        XCTAssertEqual(locationManager.stoppedRangingConstraints, [region.beaconIdentityConstraint])
    }

    func testForegroundScanCollectsEntryOnceUntilExit() throws {
        let server = Server.fake()
        let zone = AppZone(
            entityId: "beacon_region",
            serverIdentifier: server.identifier.rawValue,
            inRegion: false
        )
        try database.write { db in
            try zone.save(db)
        }
        let region = CLBeaconRegion(uuid: UUID(), identifier: zone.identifier)
        let beacon = CLBeacon(
            uuid: region.uuid,
            major: 0,
            minor: 0,
            proximity: .near,
            accuracy: 1,
            rssi: -60,
            timestamp: Date()
        )

        collector.startForegroundBeaconScanning(in: [region], manager: locationManager)
        collector.locationManager(
            locationManager,
            didRange: [beacon],
            satisfying: region.beaconIdentityConstraint
        )
        collector.locationManager(
            locationManager,
            didRange: [beacon],
            satisfying: region.beaconIdentityConstraint
        )

        XCTAssertEqual(delegate.events, [
            .init(eventType: .region(region, .inside), associatedZone: zone),
        ])
        XCTAssertTrue(locationManager.stoppedRangingConstraints.isEmpty)
    }

    func testForegroundScanCanEnterAgainAfterExit() throws {
        let server = Server.fake()
        let zone = AppZone(
            entityId: "beacon_region",
            serverIdentifier: server.identifier.rawValue,
            inRegion: false
        )
        try database.write { db in
            try zone.save(db)
        }
        let region = CLBeaconRegion(uuid: UUID(), identifier: zone.identifier)
        let beacon = CLBeacon(
            uuid: region.uuid,
            major: 0,
            minor: 0,
            proximity: .near,
            accuracy: 1,
            rssi: -60,
            timestamp: Date()
        )

        collector.startForegroundBeaconScanning(in: [region], manager: locationManager)
        collector.locationManager(
            locationManager,
            didRange: [beacon],
            satisfying: region.beaconIdentityConstraint
        )
        collector.locationManager(locationManager, didDetermineState: .outside, for: region)
        collector.locationManager(
            locationManager,
            didRange: [beacon],
            satisfying: region.beaconIdentityConstraint
        )

        XCTAssertEqual(delegate.events, [
            .init(eventType: .region(region, .inside), associatedZone: zone),
            .init(eventType: .region(region, .outside), associatedZone: zone),
            .init(eventType: .region(region, .inside), associatedZone: zone),
        ])
    }

    func testBeaconEntryIsCollectedAfterRangingConfirmation() {
        let region = CLBeaconRegion(uuid: UUID(), identifier: "beacon_region")
        let beacon = CLBeacon(
            uuid: region.uuid,
            major: 0,
            minor: 0,
            proximity: .near,
            accuracy: 1,
            rssi: -60,
            timestamp: Date()
        )

        collector.locationManager(locationManager, didDetermineState: .inside, for: region)
        collector.locationManager(
            locationManager,
            didRange: [beacon],
            satisfying: region.beaconIdentityConstraint
        )

        XCTAssertEqual(delegate.events, [.init(eventType: .region(region, .inside))])
        XCTAssertEqual(locationManager.stoppedRangingConstraints, [region.beaconIdentityConstraint])
    }

    func testBeaconEntryIgnoresUnusableRangingResult() {
        let region = CLBeaconRegion(uuid: UUID(), identifier: "beacon_region")
        let beacon = CLBeacon(
            uuid: region.uuid,
            major: 0,
            minor: 0,
            proximity: .unknown,
            accuracy: -1,
            rssi: 0,
            timestamp: Date()
        )

        collector.locationManager(locationManager, didDetermineState: .inside, for: region)
        collector.locationManager(
            locationManager,
            didRange: [beacon],
            satisfying: region.beaconIdentityConstraint
        )

        XCTAssertTrue(delegate.events.isEmpty)
        XCTAssertTrue(locationManager.stoppedRangingConstraints.isEmpty)
    }

    func testBeaconEntryIsIgnoredWhenRangingTimesOut() {
        let region = CLBeaconRegion(uuid: UUID(), identifier: "beacon_region")
        let timeoutExpectation = expectation(description: "ranging timeout")
        collector = ZoneManagerCollectorImpl(beaconVerificationTimeout: 0.01)
        delegate.onDidLog = { state in
            if case let .didIgnore(event, ZoneManagerIgnoreReason.beaconEntryNotVerified) = state,
               event.eventType == .region(region, .inside) {
                timeoutExpectation.fulfill()
            }
        }
        collector.delegate = delegate

        collector.locationManager(locationManager, didDetermineState: .inside, for: region)
        wait(for: [timeoutExpectation], timeout: 1)

        XCTAssertTrue(delegate.events.isEmpty)
        XCTAssertEqual(locationManager.stoppedRangingConstraints, [region.beaconIdentityConstraint])
    }

    func testBeaconExitIsCollected() {
        let region = CLBeaconRegion(uuid: UUID(), identifier: "beacon_region")

        collector.locationManager(locationManager, didDetermineState: .outside, for: region)

        XCTAssertEqual(delegate.events, [.init(eventType: .region(region, .outside))])
    }

    func testBeaconExitCancelsPendingEntry() {
        let region = CLBeaconRegion(uuid: UUID(), identifier: "beacon_region")
        let beacon = CLBeacon(
            uuid: region.uuid,
            major: 0,
            minor: 0,
            proximity: .near,
            accuracy: 1,
            rssi: -60,
            timestamp: Date()
        )

        collector.locationManager(locationManager, didDetermineState: .inside, for: region)
        collector.locationManager(locationManager, didDetermineState: .outside, for: region)
        collector.locationManager(
            locationManager,
            didRange: [beacon],
            satisfying: region.beaconIdentityConstraint
        )

        XCTAssertEqual(delegate.events, [.init(eventType: .region(region, .outside))])
        XCTAssertEqual(locationManager.stoppedRangingConstraints, [region.beaconIdentityConstraint])
    }

    func testBeaconCanEnterAgainAfterExit() {
        let region = CLBeaconRegion(uuid: UUID(), identifier: "beacon_region")
        let beacon = CLBeacon(
            uuid: region.uuid,
            major: 0,
            minor: 0,
            proximity: .near,
            accuracy: 1,
            rssi: -60,
            timestamp: Date()
        )

        collector.locationManager(locationManager, didDetermineState: .inside, for: region)
        collector.locationManager(
            locationManager,
            didRange: [beacon],
            satisfying: region.beaconIdentityConstraint
        )
        collector.locationManager(locationManager, didDetermineState: .outside, for: region)
        collector.locationManager(locationManager, didDetermineState: .inside, for: region)
        collector.locationManager(
            locationManager,
            didRange: [beacon],
            satisfying: region.beaconIdentityConstraint
        )

        XCTAssertEqual(delegate.events, [
            .init(eventType: .region(region, .inside)),
            .init(eventType: .region(region, .outside)),
            .init(eventType: .region(region, .inside)),
        ])
    }

    func testDidUpdateLocations() {
        let locations = [
            CLLocation(latitude: 1.23, longitude: 4.56),
            CLLocation(latitude: 2.34, longitude: 5.67),
        ]

        collector.locationManager(locationManager, didUpdateLocations: locations)
        XCTAssertEqual(delegate.events.count, 1)

        guard let event = delegate.events.first else {
            return
        }

        XCTAssertEqual(event.eventType, .locationChange(locations))
        XCTAssertNil(event.associatedZone)
    }

    func testLocationUpdateStartsShortBeaconScan() throws {
        let server = Server.fake()
        let zone = AppZone(
            entityId: "beacon_region",
            serverIdentifier: server.identifier.rawValue,
            inRegion: false
        )
        try database.write { db in
            try zone.save(db)
        }
        let region = CLBeaconRegion(uuid: UUID(), identifier: zone.identifier)
        locationManager.overrideMonitoredRegions = [region]

        collector.locationManager(
            locationManager,
            didUpdateLocations: [CLLocation(latitude: 1.23, longitude: 4.56)]
        )

        XCTAssertEqual(locationManager.startedRangingConstraints, [region.beaconIdentityConstraint])
    }

    func testOpportunisticScanCollectsEntryAndStopsRanging() throws {
        let server = Server.fake()
        let zone = AppZone(
            entityId: "beacon_region",
            serverIdentifier: server.identifier.rawValue,
            inRegion: false
        )
        try database.write { db in
            try zone.save(db)
        }
        let region = CLBeaconRegion(uuid: UUID(), identifier: zone.identifier)
        let beacon = CLBeacon(
            uuid: region.uuid,
            major: 0,
            minor: 0,
            proximity: .near,
            accuracy: 1,
            rssi: -60,
            timestamp: Date()
        )

        collector.startOpportunisticBeaconScanning(in: [region], manager: locationManager)
        collector.locationManager(
            locationManager,
            didRange: [beacon],
            satisfying: region.beaconIdentityConstraint
        )

        XCTAssertEqual(delegate.events, [
            .init(eventType: .region(region, .inside), associatedZone: zone),
        ])
        XCTAssertEqual(locationManager.stoppedRangingConstraints, [region.beaconIdentityConstraint])
    }

    func testOpportunisticScanTimesOut() throws {
        let server = Server.fake()
        let zone = AppZone(
            entityId: "beacon_region",
            serverIdentifier: server.identifier.rawValue,
            inRegion: false
        )
        try database.write { db in
            try zone.save(db)
        }
        let region = CLBeaconRegion(uuid: UUID(), identifier: zone.identifier)
        let timeoutExpectation = expectation(description: "opportunistic scan timeout")
        collector = ZoneManagerCollectorImpl(opportunisticBeaconScanDuration: 0.01)
        collector.delegate = delegate

        collector.startOpportunisticBeaconScanning(in: [region], manager: locationManager)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            timeoutExpectation.fulfill()
        }
        wait(for: [timeoutExpectation], timeout: 1)

        XCTAssertEqual(locationManager.stoppedRangingConstraints, [region.beaconIdentityConstraint])
        XCTAssertTrue(delegate.events.isEmpty)
    }

    func testIgnoredRegions() {
        let region1 = CLCircularRegion(center: .init(latitude: 1, longitude: 2), radius: 30, identifier: "1")
        let region2 = CLCircularRegion(center: .init(latitude: 2, longitude: 1), radius: 30, identifier: "2")
        collector.ignoreNextState(for: region1)
        collector.locationManager(locationManager, didDetermineState: .inside, for: region1)
        collector.locationManager(locationManager, didDetermineState: .inside, for: region2)
        XCTAssertEqual(delegate.events, [.init(eventType: .region(region2, .inside), associatedZone: nil)])
        collector.locationManager(locationManager, didDetermineState: .outside, for: region1)
        XCTAssertEqual(delegate.events, [
            .init(eventType: .region(region2, .inside), associatedZone: nil),
            .init(eventType: .region(region1, .outside), associatedZone: nil),
        ])
    }
}

private class FakeZoneManagerCollectorDelegate: ZoneManagerCollectorDelegate {
    var states = [ZoneManagerState]()
    var events = [ZoneManagerEvent]()
    var onDidLog: ((ZoneManagerState) -> Void)?

    func collector(_ collector: ZoneManagerCollector, didLog state: ZoneManagerState) {
        states.append(state)
        onDidLog?(state)
    }

    func collector(_ collector: ZoneManagerCollector, didCollect event: ZoneManagerEvent) {
        events.append(event)
    }
}
