import CoreLocation
import Foundation

/// A home (public.apartments) as the app uses it.
struct Home: Decodable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let handle: String
    let city: String?
    let theme: String
    let statusLine: String?
    let homeLat: Double
    let homeLng: Double
    let radiusM: Int

    var location: HomeLocation {
        HomeLocation(coordinate: CLLocationCoordinate2D(latitude: homeLat, longitude: homeLng), radius: Double(radiusM))
    }
}

struct Roommate: Decodable, Identifiable, Equatable {
    let userId: UUID
    let displayName: String
    let role: String
    let presence: PresenceState
    var id: UUID { userId }
    var isKeyholder: Bool { role == "keyholder" }
}

/// Server calls for homes. Rules (who may do what) live in the database.
enum HomeService {
    private static var client: SupabaseClient { .shared }
    private static let homeColumns = "id,name,handle,city,theme,status_line,home_lat,home_lng,radius_m"

    /// The home you live in, if any.
    static func currentHome() async throws -> Home? {
        struct Row: Decodable { let apartments: Home }
        let rows: [Row] = try await client.select("memberships?select=apartments(\(homeColumns))&order=joined_at.asc&limit=1")
        return rows.first?.apartments
    }

    static func setDisplayName(_ name: String) async throws {
        let session = try await client.ensureSession()
        try await client.update("users", where: "id=eq.\(session.userID.uuidString)", ["display_name": name])
    }

    struct NewHome {
        var name: String
        var statusLine: String
        var theme: String
        var coordinate: CLLocationCoordinate2D
        var radius: Int
        var city: String?
    }

    /// Creates the home (you become its first Keyholder). Retries with a
    /// number on the handle if someone already has it.
    static func create(_ new: NewHome) async throws -> Home {
        let base = handle(for: new.name)
        var lastError: Error?
        for attempt in 0..<5 {
            let handle = attempt == 0 ? base : "\(base.prefix(26))\(Int.random(in: 10...999))"
            do {
                let row: Home = try await client.rpc("create_apartment", CreateParams(
                    handle: handle, name: new.name, lat: new.coordinate.latitude, lng: new.coordinate.longitude,
                    radius: new.radius, status: new.statusLine.isEmpty ? nil : new.statusLine, city: new.city))
                try await setTheme(row.id, new.theme)
                return Home(id: row.id, name: row.name, handle: row.handle, city: row.city, theme: new.theme,
                            statusLine: row.statusLine, homeLat: row.homeLat, homeLng: row.homeLng, radiusM: row.radiusM)
            } catch SupabaseClient.ClientError.http(let status, let body) where status == 409 || body.contains("23505") {
                lastError = SupabaseClient.ClientError.http(status: status, body: body)
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    static func setTheme(_ homeID: UUID, _ theme: String) async throws {
        try await client.update("apartments", where: "id=eq.\(homeID.uuidString)", ["theme": theme])
    }

    static func roster(_ homeID: UUID) async throws -> [Roommate] {
        try await client.rpcList("apartment_roster", ["p_apartment_id": homeID])
    }

    static func inviteLink(_ homeID: UUID) async throws -> (code: String, url: URL) {
        struct Invite: Decodable { let code: String }
        let invite: Invite = try await client.rpc("create_invite", ["p_apartment_id": homeID])
        return (invite.code, URL(string: "https://\(InviteLink.host)/j/\(invite.code)")!)
    }

    /// "The Burrow" → "theburrow" (3–30 of a–z, 0–9, _).
    static func handle(for name: String) -> String {
        let cleaned = name.lowercased().filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        let trimmed = String(cleaned.prefix(30))
        return trimmed.count >= 3 ? trimmed : trimmed + "home"
    }
}

private struct CreateParams: Encodable {
    let handle: String
    let name: String
    let lat: Double
    let lng: Double
    let radius: Int
    let status: String?
    let city: String?

    enum CodingKeys: String, CodingKey {
        case handle = "p_handle", name = "p_name", lat = "p_home_lat", lng = "p_home_lng"
        case radius = "p_radius_m", status = "p_status_line", city = "p_city"
    }
}
