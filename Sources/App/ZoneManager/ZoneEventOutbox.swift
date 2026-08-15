import Foundation
import Shared

struct PendingZoneEvent: Codable, Equatable {
    let id: UUID
    let serverIdentifier: String
    let eventType: String
    let eventData: Data
    let createdAt: Date
    let isBeacon: Bool?

    init(
        id: UUID = UUID(),
        serverIdentifier: String,
        eventType: String,
        eventData: [String: Any],
        createdAt: Date = Date(),
        isBeacon: Bool = false
    ) throws {
        self.id = id
        self.serverIdentifier = serverIdentifier
        self.eventType = eventType
        self.eventData = try JSONSerialization.data(withJSONObject: eventData, options: [.sortedKeys])
        self.createdAt = createdAt
        self.isBeacon = isBeacon
    }

    var decodedEventData: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: eventData)) as? [String: Any]
    }
}

protocol ZoneEventOutbox: AnyObject {
    var pendingEvents: [PendingZoneEvent] { get }
    func append(_ event: PendingZoneEvent)
    func remove(id: UUID)
}

final class UserDefaultsZoneEventOutbox: ZoneEventOutbox {
    private let defaults: UserDefaults
    private let key: String
    private let queue = DispatchQueue(label: "io.robbie.HomeAssistant.ZoneEventOutbox")
    private let maximumEventCount = 100
    private let maximumEventAge: TimeInterval = 7 * 24 * 60 * 60

    init(
        defaults: UserDefaults = UserDefaults(suiteName: AppConstants.AppGroupID) ?? .standard,
        key: String = "zoneEventOutbox.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    var pendingEvents: [PendingZoneEvent] {
        queue.sync { load() }
    }

    func append(_ event: PendingZoneEvent) {
        queue.sync {
            var events = load().filter { Date().timeIntervalSince($0.createdAt) <= maximumEventAge }
            guard !events.contains(where: { $0.id == event.id }) else { return }
            events.append(event)
            events = Array(events.suffix(maximumEventCount))
            save(events)
        }
    }

    func remove(id: UUID) {
        queue.sync {
            var events = load()
            events.removeAll { $0.id == id }
            save(events)
        }
    }

    private func load() -> [PendingZoneEvent] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PendingZoneEvent].self, from: data)) ?? []
    }

    private func save(_ events: [PendingZoneEvent]) {
        if events.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: key)
        }
    }
}
