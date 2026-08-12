import CoreLocation
import PromiseKit
import Shared

protocol ZoneManagerCollectorDelegate: AnyObject {
    func collector(_ collector: ZoneManagerCollector, didLog state: ZoneManagerState)
    func collector(_ collector: ZoneManagerCollector, didCollect event: ZoneManagerEvent)
}

protocol ZoneManagerCollector: CLLocationManagerDelegate {
    var delegate: ZoneManagerCollectorDelegate? { get set }
    func ignoreNextState(for region: CLRegion)
    func startForegroundBeaconScanning(in regions: Set<CLRegion>, manager: CLLocationManager)
    func stopForegroundBeaconScanning(manager: CLLocationManager)
    func startOpportunisticBeaconScanning(in regions: Set<CLRegion>, manager: CLLocationManager)
}

class ZoneManagerCollectorImpl: NSObject, ZoneManagerCollector {
    private struct PendingBeaconEntry {
        let event: ZoneManagerEvent
        let constraint: CLBeaconIdentityConstraint
        let timeout: DispatchWorkItem
    }

    private struct ForegroundBeaconEntry {
        let event: ZoneManagerEvent
        let region: CLBeaconRegion
        let constraint: CLBeaconIdentityConstraint
    }

    private struct BeaconReconciliationState {
        var emptySampleCount = 0
        var firstEmptySampleAt: Date?
    }

    weak var delegate: ZoneManagerCollectorDelegate?

    private var ignoredNextRegions = Set<CLRegion>()
    private var pendingBeaconEntries = [String: PendingBeaconEntry]()
    private var foregroundBeaconEntries = [String: ForegroundBeaconEntry]()
    private var foregroundBeaconIdentifiersInside = Set<String>()
    private var opportunisticBeaconEntries = [String: ForegroundBeaconEntry]()
    private var beaconReconciliationStates = [String: BeaconReconciliationState]()
    private var beaconRangingRetryCounts = [CLBeaconIdentityConstraint: Int]()
    private var beaconRangingRetryWorkItems = [CLBeaconIdentityConstraint: DispatchWorkItem]()
    private var opportunisticBeaconScanTimeout: DispatchWorkItem?
    private let beaconVerificationTimeout: TimeInterval
    private let opportunisticBeaconScanDuration: TimeInterval
    private let beaconExitReconciliationDuration: TimeInterval
    private let beaconExitMinimumEmptySamples: Int
    private let beaconRangingRetryLimit: Int
    private let beaconRangingRetryDelay: TimeInterval

    init(
        beaconVerificationTimeout: TimeInterval = 10,
        opportunisticBeaconScanDuration: TimeInterval = 10,
        beaconExitReconciliationDuration: TimeInterval = 8,
        beaconExitMinimumEmptySamples: Int = 3,
        beaconRangingRetryLimit: Int = 2,
        beaconRangingRetryDelay: TimeInterval = 1
    ) {
        self.beaconVerificationTimeout = beaconVerificationTimeout
        self.opportunisticBeaconScanDuration = opportunisticBeaconScanDuration
        self.beaconExitReconciliationDuration = beaconExitReconciliationDuration
        self.beaconExitMinimumEmptySamples = beaconExitMinimumEmptySamples
        self.beaconRangingRetryLimit = beaconRangingRetryLimit
        self.beaconRangingRetryDelay = beaconRangingRetryDelay
    }

    func ignoreNextState(for region: CLRegion) {
        ignoredNextRegions.insert(region)
    }

    func startForegroundBeaconScanning(in regions: Set<CLRegion>, manager: CLLocationManager) {
        stopForegroundBeaconScanning(manager: manager)

        for region in regions.compactMap({ $0 as? CLBeaconRegion }) {
            let event = Self.event(for: region, state: .inside)
            guard let zone = event.associatedZone else { continue }

            foregroundBeaconEntries[region.identifier] = ForegroundBeaconEntry(
                event: event,
                region: region,
                constraint: region.beaconIdentityConstraint
            )
            if zone.inRegion {
                foregroundBeaconIdentifiersInside.insert(region.identifier)
            }
            manager.startRangingBeacons(satisfying: region.beaconIdentityConstraint)
        }
    }

    func stopForegroundBeaconScanning(manager: CLLocationManager) {
        for (identifier, entry) in foregroundBeaconEntries
            where pendingBeaconEntries[identifier] == nil && opportunisticBeaconEntries[identifier] == nil {
            manager.stopRangingBeacons(satisfying: entry.constraint)
        }

        foregroundBeaconEntries.removeAll()
        foregroundBeaconIdentifiersInside.removeAll()
        beaconReconciliationStates.removeAll()
    }

    func startOpportunisticBeaconScanning(in regions: Set<CLRegion>, manager: CLLocationManager) {
        // Foreground ranging is already continuous, so an additional timed scan
        // would only duplicate work.
        guard foregroundBeaconEntries.isEmpty else { return }

        stopOpportunisticBeaconScanning(manager: manager)

        for region in regions.compactMap({ $0 as? CLBeaconRegion }) {
            let event = Self.event(for: region, state: .inside)
            guard let zone = event.associatedZone else { continue }

            opportunisticBeaconEntries[region.identifier] = ForegroundBeaconEntry(
                event: event,
                region: region,
                constraint: region.beaconIdentityConstraint
            )
            if zone.inRegion {
                foregroundBeaconIdentifiersInside.insert(region.identifier)
            }
            manager.startRangingBeacons(satisfying: region.beaconIdentityConstraint)
        }

        guard !opportunisticBeaconEntries.isEmpty else { return }

        let timeout = DispatchWorkItem { [weak self, weak manager] in
            guard let self, let manager else { return }
            self.reconcileBeaconExits()
            self.stopOpportunisticBeaconScanning(manager: manager)
        }
        opportunisticBeaconScanTimeout = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + opportunisticBeaconScanDuration,
            execute: timeout
        )
    }

    private func stopOpportunisticBeaconScanning(manager: CLLocationManager) {
        opportunisticBeaconScanTimeout?.cancel()
        opportunisticBeaconScanTimeout = nil

        for (identifier, entry) in opportunisticBeaconEntries
            where foregroundBeaconEntries[identifier] == nil && pendingBeaconEntries[identifier] == nil {
            manager.stopRangingBeacons(satisfying: entry.constraint)
            foregroundBeaconIdentifiersInside.remove(identifier)
            beaconReconciliationStates.removeValue(forKey: identifier)
        }
        opportunisticBeaconEntries.removeAll()
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        delegate?.collector(self, didLog: .didError(error))
    }

    func locationManager(
        _ manager: CLLocationManager,
        monitoringDidFailFor region: CLRegion?,
        withError error: Error
    ) {
        delegate?.collector(self, didLog: .didFailMonitoring(region, error))
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        rangingBeaconsDidFailFor beaconConstraint: CLBeaconIdentityConstraint,
        withError error: Error
    ) {
        delegate?.collector(self, didLog: .didFailRanging(beaconConstraint, error))

        guard hasActiveRangingEntry(for: beaconConstraint),
              beaconRangingRetryCounts[beaconConstraint, default: 0] < beaconRangingRetryLimit,
              beaconRangingRetryWorkItems[beaconConstraint] == nil else { return }

        beaconRangingRetryCounts[beaconConstraint, default: 0] += 1
        let retry = DispatchWorkItem { [weak self, weak manager] in
            guard let self else { return }
            self.beaconRangingRetryWorkItems.removeValue(forKey: beaconConstraint)
            guard self.hasActiveRangingEntry(for: beaconConstraint) else { return }
            manager?.startRangingBeacons(satisfying: beaconConstraint)
        }
        beaconRangingRetryWorkItems[beaconConstraint] = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + beaconRangingRetryDelay, execute: retry)
    }

    func locationManager(
        _ manager: CLLocationManager,
        didStartMonitoringFor region: CLRegion
    ) {
        delegate?.collector(self, didLog: .didStartMonitoring(region))
    }

    func locationManager(
        _ manager: CLLocationManager,
        didDetermineState state: CLRegionState,
        for region: CLRegion
    ) {
        guard !ignoredNextRegions.contains(region) else {
            ignoredNextRegions.remove(region)
            return
        }

        let event = Self.event(for: region, state: state)

        if let beaconRegion = region as? CLBeaconRegion {
            switch state {
            case .inside:
                guard !foregroundBeaconIdentifiersInside.contains(beaconRegion.identifier) else { return }
                verifyBeaconEntry(event, region: beaconRegion, manager: manager)
                return
            case .outside:
                cancelPendingBeaconEntry(for: beaconRegion, manager: manager)
                cancelOpportunisticBeaconEntry(for: beaconRegion, manager: manager)
                foregroundBeaconIdentifiersInside.remove(beaconRegion.identifier)
            case .unknown:
                break
            }
        }

        delegate?.collector(self, didCollect: event)
    }

    func locationManager(
        _ manager: CLLocationManager,
        didRange beacons: [CLBeacon],
        satisfying beaconConstraint: CLBeaconIdentityConstraint
    ) {
        beaconRangingRetryCounts.removeValue(forKey: beaconConstraint)
        beaconRangingRetryWorkItems.removeValue(forKey: beaconConstraint)?.cancel()

        let pendingIdentifiers = pendingBeaconEntries.compactMap {
            $0.value.constraint == beaconConstraint ? $0.key : nil
        }
        let foregroundIdentifiers = foregroundBeaconEntries.compactMap {
            $0.value.constraint == beaconConstraint ? $0.key : nil
        }
        let opportunisticIdentifiers = opportunisticBeaconEntries.compactMap {
            $0.value.constraint == beaconConstraint ? $0.key : nil
        }
        let identifiers = Set(pendingIdentifiers + foregroundIdentifiers + opportunisticIdentifiers)

        guard beacons.contains(where: Self.isBeaconInsideRange) else {
            reconcileEmptyBeaconSample(identifiers: Array(identifiers))
            return
        }

        identifiers.forEach { beaconReconciliationStates.removeValue(forKey: $0) }

        var events = [ZoneManagerEvent]()
        for pendingIdentifier in pendingIdentifiers {
            guard let pending = pendingBeaconEntries.removeValue(forKey: pendingIdentifier) else { continue }
            pending.timeout.cancel()
            if !foregroundIdentifiers.contains(pendingIdentifier) ||
                !foregroundBeaconIdentifiersInside.contains(pendingIdentifier) {
                if !events.contains(pending.event) {
                    events.append(pending.event)
                }
            }
        }

        for foregroundIdentifier in foregroundIdentifiers
            where !foregroundBeaconIdentifiersInside.contains(foregroundIdentifier) {
            guard let foreground = foregroundBeaconEntries[foregroundIdentifier] else { continue }
            foregroundBeaconIdentifiersInside.insert(foregroundIdentifier)
            if !events.contains(foreground.event) {
                events.append(foreground.event)
            }
        }

        for opportunisticIdentifier in opportunisticIdentifiers {
            guard let opportunistic = opportunisticBeaconEntries.removeValue(forKey: opportunisticIdentifier) else {
                continue
            }
            if !events.contains(opportunistic.event) {
                events.append(opportunistic.event)
            }
            if !foregroundIdentifiers.contains(opportunisticIdentifier) &&
                pendingBeaconEntries[opportunisticIdentifier] == nil {
                foregroundBeaconIdentifiersInside.remove(opportunisticIdentifier)
                beaconReconciliationStates.removeValue(forKey: opportunisticIdentifier)
            }
        }

        if !hasActiveRangingEntry(for: beaconConstraint) {
            manager.stopRangingBeacons(satisfying: beaconConstraint)
        }

        events.forEach { delegate?.collector(self, didCollect: $0) }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        startOpportunisticBeaconScanning(in: manager.monitoredRegions, manager: manager)

        let event = ZoneManagerEvent(
            eventType: .locationChange(locations)
        )

        delegate?.collector(self, didCollect: event)
    }

    private func verifyBeaconEntry(
        _ event: ZoneManagerEvent,
        region: CLBeaconRegion,
        manager: CLLocationManager
    ) {
        let identifier = region.identifier
        let constraint = region.beaconIdentityConstraint

        if let pending = pendingBeaconEntries.removeValue(forKey: identifier) {
            pending.timeout.cancel()
            if !hasActiveRangingEntry(for: pending.constraint) {
                manager.stopRangingBeacons(satisfying: pending.constraint)
            }
        }

        let timeout = DispatchWorkItem { [weak self, weak manager] in
            guard let self,
                  let pending = self.pendingBeaconEntries.removeValue(forKey: identifier) else { return }

            if !self.hasActiveRangingEntry(for: pending.constraint) {
                manager?.stopRangingBeacons(satisfying: pending.constraint)
            }
            self.delegate?.collector(
                self,
                didLog: .didIgnore(event, ZoneManagerIgnoreReason.beaconEntryNotVerified)
            )
        }

        pendingBeaconEntries[identifier] = PendingBeaconEntry(
            event: event,
            constraint: constraint,
            timeout: timeout
        )
        manager.startRangingBeacons(satisfying: constraint)
        DispatchQueue.main.asyncAfter(deadline: .now() + beaconVerificationTimeout, execute: timeout)
    }

    private func cancelPendingBeaconEntry(for region: CLBeaconRegion, manager: CLLocationManager) {
        guard let pending = pendingBeaconEntries.removeValue(forKey: region.identifier) else { return }

        pending.timeout.cancel()
        if !hasActiveRangingEntry(for: pending.constraint) {
            manager.stopRangingBeacons(satisfying: pending.constraint)
        }
    }

    private func cancelOpportunisticBeaconEntry(for region: CLBeaconRegion, manager: CLLocationManager) {
        guard let entry = opportunisticBeaconEntries.removeValue(forKey: region.identifier) else { return }

        if !hasActiveRangingEntry(for: entry.constraint) {
            manager.stopRangingBeacons(satisfying: entry.constraint)
        }
    }

    private func reconcileEmptyBeaconSample(identifiers: [String]) {
        let now = Date()

        for identifier in Set(identifiers) where foregroundBeaconIdentifiersInside.contains(identifier) {
            var state = beaconReconciliationStates[identifier] ?? BeaconReconciliationState()
            state.emptySampleCount += 1
            state.firstEmptySampleAt = state.firstEmptySampleAt ?? now
            beaconReconciliationStates[identifier] = state
        }

        reconcileBeaconExits(now: now)
    }

    private func reconcileBeaconExits(now: Date = Date()) {
        let identifiersToExit = beaconReconciliationStates.compactMap { identifier, state -> String? in
            guard state.emptySampleCount >= beaconExitMinimumEmptySamples,
                  let firstEmptySampleAt = state.firstEmptySampleAt,
                  now.timeIntervalSince(firstEmptySampleAt) >= beaconExitReconciliationDuration,
                  foregroundBeaconIdentifiersInside.contains(identifier),
                  foregroundBeaconEntries[identifier] != nil || opportunisticBeaconEntries[identifier] != nil
            else { return nil }

            return identifier
        }

        for identifier in identifiersToExit {
            guard foregroundBeaconIdentifiersInside.remove(identifier) != nil,
                  let entry = foregroundBeaconEntries[identifier] ?? opportunisticBeaconEntries[identifier]
            else { continue }

            beaconReconciliationStates.removeValue(forKey: identifier)
            delegate?.collector(
                self,
                didCollect: Self.event(for: entry.region, state: .outside)
            )
        }
    }

    private static func isBeaconInsideRange(_ beacon: CLBeacon) -> Bool {
        guard beacon.rssi != 0 else { return false }

        switch beacon.proximity {
        case .immediate, .near:
            return true
        case .far, .unknown:
            return false
        @unknown default:
            return false
        }
    }

    private func hasActiveRangingEntry(for constraint: CLBeaconIdentityConstraint) -> Bool {
        pendingBeaconEntries.values.contains { $0.constraint == constraint } ||
            foregroundBeaconEntries.values.contains { $0.constraint == constraint } ||
            opportunisticBeaconEntries.values.contains { $0.constraint == constraint }
    }

    private static func event(for region: CLRegion, state: CLRegionState) -> ZoneManagerEvent {
        // regions for small zones are suffixed with "@<angle>"; the zone's
        // identifier is the prefix
        let baseIdentifier = region.identifier.components(separatedBy: "@").first ?? region.identifier
        var zone = AppZone.zone(identifier: region.identifier)
        if zone == nil, baseIdentifier != region.identifier {
            zone = AppZone.zone(identifier: baseIdentifier)
        }

        return ZoneManagerEvent(
            eventType: .region(region, state),
            associatedZone: zone
        )
    }
}
