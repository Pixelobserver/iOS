import CoreLocation
import Foundation
import GRDB
import PromiseKit
import Shared
import UIKit

class ZoneManager {
    let locationManager: CLLocationManager
    let collector: ZoneManagerCollector
    let processor: ZoneManagerProcessor
    let regionFilter: ZoneManagerRegionFilter
    let zoneEventOutbox: ZoneEventOutbox
    private(set) var zones: [AppZone]

    private var observationToken: AnyDatabaseCancellable?
    private var drainingZoneEventIDs = Set<UUID>()

    init(
        locationManager: CLLocationManager = .init(),
        collector: ZoneManagerCollector = ZoneManagerCollectorImpl(),
        processor: ZoneManagerProcessor = ZoneManagerProcessorImpl(),
        regionFilter: ZoneManagerRegionFilter = ZoneManagerRegionFilterImpl(),
        zoneEventOutbox: ZoneEventOutbox = UserDefaultsZoneEventOutbox()
    ) {
        self.locationManager = locationManager
        self.collector = collector
        self.processor = processor
        self.regionFilter = regionFilter
        self.zoneEventOutbox = zoneEventOutbox
        self.zones = AppZone.trackedZones()

        self.collector.delegate = self
        self.processor.delegate = self

        log(state: .initialize)

        updateLocationManager(isInitial: true)
        DispatchQueue.main.async { [weak self] in
            self?.flushPendingZoneEvents()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(locationSettingDidChange),
            name: SettingsStore.locationRelatedSettingDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }

    deinit {
        observationToken?.cancel()
        NotificationCenter.default.removeObserver(self)
        Current.Log.info("going away")
    }

    @objc private func locationSettingDidChange() {
        updateLocationManager(isInitial: false)
    }

    @objc func applicationDidBecomeActive() {
        collector.stopBackgroundBeaconMonitoring(manager: locationManager)
        guard Current.settingsStore.locationSources.zone else { return }

        flushPendingZoneEvents()

        collector.startForegroundBeaconScanning(
            in: locationManager.monitoredRegions,
            manager: locationManager
        )
    }

    @objc func applicationWillResignActive() {
        collector.stopForegroundBeaconScanning(manager: locationManager)
        guard Current.settingsStore.locationSources.zone else { return }
        collector.startBackgroundBeaconMonitoring(
            in: locationManager.monitoredRegions,
            manager: locationManager
        )
    }

    private func updateLocationManager(isInitial: Bool) {
        with(locationManager) {
            $0.delegate = collector
            $0.allowsBackgroundLocationUpdates = true
            $0.pausesLocationUpdatesAutomatically = false

            if Current.settingsStore.locationSources.significantLocationChange {
                Current.Log.info("started monitoring siglog changes")
                $0.startMonitoringSignificantLocationChanges()
            } else {
                Current.Log.info("not monitoring siglog changes")
                $0.stopMonitoringSignificantLocationChanges()
            }
        }

        if isInitial {
            let observation = ValueObservation.tracking { db in
                try AppZone
                    .filter(Column(DatabaseTables.AppZone.trackingEnabled.rawValue) == true)
                    .fetchAll(db)
            }
            // .immediate delivers the initial zones synchronously (we are on the
            // main queue), matching the previous Realm behavior of monitoring
            // regions as soon as the manager is created.
            observationToken = observation.start(
                in: Current.database(),
                scheduling: .immediate,
                onError: { error in
                    Current.Log.error("couldn't sync zones: \(error)")
                },
                onChange: { [weak self] zones in
                    guard let self else { return }
                    self.zones = zones
                    sync(zones: AnyCollection(zones))
                }
            )
        } else {
            sync(zones: AnyCollection(zones))
        }
    }

    private func log(state: ZoneManagerState) {
        Current.Log.info(state)
    }

    private func perform(event: ZoneManagerEvent) {
        // although technically the processor also does this, it does it after some async processing.
        // let's be very confident that we're not going to miss out on an update due to being suspended,
        // so the background task starts before any asynchronous work (like fetching the current SSID).
        let performPromise = Current.backgroundTask(withName: BackgroundTask.zoneManagerPerformEvent.rawValue) { _ in
            processor.perform(event: event)
        }.get { [weak self] _ in
            // a location change means we should consider changing our monitored regions
            // ^ not tap for this side effect because we don't want to do this on failure
            guard let self else { return }
            sync(zones: AnyCollection(zones))
        }

        Guarantee<String?> { seal in
            Task {
                await seal(Current.connectivity.currentWiFiSSID())
            }
        }.done { currentSSID in
            let logPayload: [String: String] = [
                "start_ssid": currentSSID ?? "none",
                "event": event.description,
            ]

            performPromise.done {
                Current.clientEventStore.addEvent(ClientEvent(
                    text: "Updated location",
                    type: .locationUpdate,
                    payload: logPayload
                ))
            }.catch { error in
                Current.Log.error("ZoneManagerPerformEvent background task error for \(event): \(error)")

                var updatedPayload = logPayload
                updatedPayload["error"] = String(describing: error)

                Current.clientEventStore.addEvent(ClientEvent(
                    text: "Didn't update: \(error.localizedDescription)",
                    type: .locationUpdate,
                    payload: updatedPayload
                ))

                Current.notificationDispatcher.send(.init(
                    id: .debug,
                    title: "DEBUG: Failed to perform ZoneManager event",
                    body: "Event: \(event.eventType.description), error: \(error.localizedDescription)"
                ))
            }
        }
    }

    private func fire(event: ZoneManagerEvent) {
        if case .locationChange = event.eventType {
            flushPendingZoneEvents()
            return
        }

        guard let zone = event.associatedZone,
              let server = Current.servers.server(forServerIdentifier: zone.serverIdentifier) else { return }

        switch event.eventType {
        case let .region(region, state):
            guard let api = Current.api(for: server) else {
                Current.Log.error("No API available to fire ZoneManager event, server: \(server)")
                return
            }
            let eventInfo = api.zoneStateEvent(region: region, state: state, zone: zone)
            enqueueZoneEvent(
                serverIdentifier: server.identifier.rawValue,
                eventType: eventInfo.eventType,
                eventData: eventInfo.eventData
            )
        case .locationChange:
            break
        }
    }

    private func enqueueZoneEvent(
        serverIdentifier: String,
        eventType: String,
        eventData: [String: Any]
    ) {
        do {
            let pending = try PendingZoneEvent(
                serverIdentifier: serverIdentifier,
                eventType: eventType,
                eventData: eventData
            )
            // Persist before any asynchronous URL resolution or URLSession task creation.
            // iOS may suspend us at either boundary; the next wake can then resume delivery.
            zoneEventOutbox.append(pending)
            flushPendingZoneEvents()
        } catch {
            let message = "Failed to persist ZoneManager event before delivery: \(error.localizedDescription)"
            Current.Log.error(message)
            Current.clientEventStore.addEvent(.init(text: message, type: .locationUpdate))
        }
    }

    private func startZoneEvent(
        api: HomeAssistantAPI,
        pendingEvent: PendingZoneEvent,
        eventData: [String: Any]
    ) -> Bool {
        let startResult = api.StartPersistentEvent(
            eventType: pendingEvent.eventType,
            eventData: eventData
        )

        guard case let .success(delivery) = startResult else {
            if case let .failure(error) = startResult {
                let message = "Failed to start ZoneManager background upload; queued for retry: " +
                    error.localizedDescription
                Current.Log.error(message)
                Current.clientEventStore.addEvent(.init(text: message, type: .locationUpdate))
            }
            return false
        }

        drainingZoneEventIDs.insert(pendingEvent.id)
        delivery.pipe { [weak self] result in
            DispatchQueue.main.async {
                self?.handleZoneEventResult(
                    result,
                    pendingEvent: pendingEvent
                )
            }
        }
        return true
    }

    private func handleZoneEventResult(
        _ result: Result<Void>,
        pendingEvent: PendingZoneEvent
    ) {
        drainingZoneEventIDs.remove(pendingEvent.id)

        switch result {
        case .fulfilled:
            zoneEventOutbox.remove(id: pendingEvent.id)
            flushPendingZoneEvents()
            Current.Log.info("Fired ZoneManager event")
        case let .rejected(error):
            let message = "Failed to fire ZoneManager event; queued for retry: \(error.localizedDescription)"
            Current.Log.error(message)
            Current.clientEventStore.addEvent(.init(text: message, type: .locationUpdate))
            Current.notificationDispatcher.send(.init(
                id: .debug,
                title: "DEBUG: Failed to fire ZoneManager",
                body: message
            ))
        }
    }

    private func flushPendingZoneEvents() {
        guard let pending = zoneEventOutbox.pendingEvents.first,
              !drainingZoneEventIDs.contains(pending.id),
              let eventData = pending.decodedEventData,
              let server = Current.servers.server(
                  forServerIdentifier: pending.serverIdentifier
              ),
              let api = Current.api(for: server) else { return }

        _ = startZoneEvent(
            api: api,
            pendingEvent: pending,
            eventData: eventData
        )
    }

    private func sync(zones: AnyCollection<AppZone>) {
        let currentRegions = locationManager.monitoredRegions
        let desiredRegions = regionFilter.regions(
            from: zones,
            currentRegions: AnyCollection(currentRegions),
            lastLocation: locationManager.location
        )

        let actual = Set(currentRegions.map(ZoneManagerEquatableRegion.init(region:)))
        let expected: Set<ZoneManagerEquatableRegion>

        if Current.settingsStore.locationSources.zone {
            expected = Set(desiredRegions.map(ZoneManagerEquatableRegion.init(region:)))
        } else {
            expected = Set()
        }

        let needsRemoval = actual.subtracting(expected)
        let needsAddition = expected.subtracting(actual)

        // process removals before additions
        // this is important because the system is focused on identifier
        for region in needsRemoval.map(\.region) {
            Current.clientEventStore.addEvent(ClientEvent(
                text: "Ending monitoring \(region.identifier)",
                type: .locationUpdate,
                payload: [
                    "region": String(describing: region),
                ]
            ))
            locationManager.stopMonitoring(for: region)
        }

        for region in needsAddition.map(\.region) {
            Current.clientEventStore.addEvent(ClientEvent(
                text: "Initially monitoring \(region.identifier)",
                type: .locationUpdate,
                payload: [
                    "region": String(describing: region),
                ]
            ))

            if !region.identifier.hasSuffix(AppZone.beaconApproachRegionSuffix) {
                collector.ignoreNextState(for: region)
            }
            locationManager.startMonitoring(for: region)
        }

        let counts = (
            beacon: expected.filter { $0.region is CLBeaconRegion }.count,
            circular: expected.filter { $0.region is CLCircularRegion }.count,
            zone: Set(zones).count
        )

        Current.Log.info {
            let info = [
                "available \(zones.count)",
                "enabled \(Current.settingsStore.locationSources.zone)",
                "monitoring \(expected.count) (\(counts))",
                "started \(needsAddition.count)",
                "ended \(needsRemoval.count)",
            ]
            return info.joined(separator: ", ")
        }

        if UIApplication.shared.applicationState != .active {
            if locationManager.monitoredRegions.contains(where: { $0 is CLBeaconRegion }) {
                collector.startBackgroundBeaconMonitoring(
                    in: locationManager.monitoredRegions,
                    manager: locationManager
                )
            } else {
                collector.stopBackgroundBeaconMonitoring(manager: locationManager)
            }
        }
    }
}

extension ZoneManager: ZoneManagerCollectorDelegate {
    func collector(_ collector: ZoneManagerCollector, didLog state: ZoneManagerState) {
        log(state: state)
    }

    func collector(_ collector: ZoneManagerCollector, didCollect event: ZoneManagerEvent) {
        fire(event: event)
        perform(event: event)
    }
}

extension ZoneManager: ZoneManagerProcessorDelegate {
    func processor(_ processor: ZoneManagerProcessor, didLog state: ZoneManagerState) {
        log(state: state)
    }
}
