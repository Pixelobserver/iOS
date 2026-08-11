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
}

class ZoneManagerCollectorImpl: NSObject, ZoneManagerCollector {
    private struct PendingBeaconEntry {
        let event: ZoneManagerEvent
        let constraint: CLBeaconIdentityConstraint
        let timeout: DispatchWorkItem
    }

    private struct ForegroundBeaconEntry {
        let event: ZoneManagerEvent
        let constraint: CLBeaconIdentityConstraint
    }

    weak var delegate: ZoneManagerCollectorDelegate?

    private var ignoredNextRegions = Set<CLRegion>()
    private var pendingBeaconEntries = [String: PendingBeaconEntry]()
    private var foregroundBeaconEntries = [String: ForegroundBeaconEntry]()
    private var foregroundBeaconIdentifiersInside = Set<String>()
    private let beaconVerificationTimeout: TimeInterval

    init(beaconVerificationTimeout: TimeInterval = 5) {
        self.beaconVerificationTimeout = beaconVerificationTimeout
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
            where pendingBeaconEntries[identifier] == nil {
            manager.stopRangingBeacons(satisfying: entry.constraint)
        }

        foregroundBeaconEntries.removeAll()
        foregroundBeaconIdentifiersInside.removeAll()
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
        let pendingIdentifier = pendingBeaconEntries.first(where: {
            $0.value.constraint == beaconConstraint
        })?.key
        let foregroundIdentifier = foregroundBeaconEntries.first(where: {
            $0.value.constraint == beaconConstraint
        })?.key

        guard beacons.contains(where: { $0.rssi != 0 && $0.proximity != .unknown }) else { return }

        var event: ZoneManagerEvent?
        if let pendingIdentifier,
           let pending = pendingBeaconEntries.removeValue(forKey: pendingIdentifier) {
            pending.timeout.cancel()
            if foregroundIdentifier == nil ||
                !foregroundBeaconIdentifiersInside.contains(pendingIdentifier) {
                event = pending.event
            }
            if foregroundIdentifier == nil {
                manager.stopRangingBeacons(satisfying: pending.constraint)
            }
        }

        if let foregroundIdentifier,
           let foreground = foregroundBeaconEntries[foregroundIdentifier],
           !foregroundBeaconIdentifiersInside.contains(foregroundIdentifier) {
            foregroundBeaconIdentifiersInside.insert(foregroundIdentifier)
            event = foreground.event
        }

        if let event {
            delegate?.collector(self, didCollect: event)
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
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
            manager.stopRangingBeacons(satisfying: pending.constraint)
        }

        let timeout = DispatchWorkItem { [weak self, weak manager] in
            guard let self,
                  let pending = self.pendingBeaconEntries.removeValue(forKey: identifier) else { return }

            if self.foregroundBeaconEntries[identifier] == nil {
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
        if foregroundBeaconEntries[region.identifier] == nil {
            manager.stopRangingBeacons(satisfying: pending.constraint)
        }
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
