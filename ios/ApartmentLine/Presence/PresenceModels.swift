import CoreLocation
import Foundation

enum PresenceState: String, Codable {
    case home, away, unknown
}

enum PresenceSource: String, Codable {
    case geofence, manual, heartbeat
}

/// One report bound for `report_presence`. Queued on disk until the server has it,
/// so a crossing seen with no signal (leaving home is the usual case) still lands,
/// with the time the phone saw it.
struct PresenceReport: Codable, Identifiable, Equatable {
    var id = UUID()
    var state: PresenceState
    var source: PresenceSource
    var reportedAt: Date
    var detail: [String: String] = [:]
    var deliveredAt: Date?
}

/// The home geofence. Phase 0 keeps it on the phone; from Phase 1 it comes from
/// the apartment profile (apartments.home_lat/home_lng/radius_m).
struct HomeLocation: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var radius: Double = 100

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(coordinate: CLLocationCoordinate2D, radius: Double) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        self.radius = radius
    }
}

/// Row shape returned by `report_presence` (a public.devices row).
struct DeviceRow: Decodable {
    let id: UUID
    let presence: PresenceState
    let presenceSource: PresenceSource?
    let presenceAt: Date?
}

/// Small JSON file in Application Support. Default data protection
/// (until first unlock) keeps it readable during locked background launches.
struct JSONFile<Value: Codable> {
    let url: URL

    init(_ name: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(name)
    }

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
