import Foundation

/// Invite links look like https://homephone.app/j/<code>. Shared by the
/// app and the App Clip.
enum InviteLink {
    static let host = "homephone.app"

    static func code(from url: URL?) -> String? {
        guard let url, url.host == host || url.host == "www.\(host)" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0] == "j" else { return nil }
        let code = parts[1]
        return code.range(of: "^[A-Za-z0-9]{6,32}$", options: .regularExpression) != nil ? code : nil
    }

    struct Preview: Decodable, Equatable {
        let homeName: String
        let handle: String
        let city: String?
        let theme: String
        let invitedBy: String?
        let roommates: Int
        let isFull: Bool
    }

    struct Membership: Decodable {
        let apartmentId: UUID
    }

    static func preview(_ code: String) async throws -> Preview? {
        let rows: [Preview] = try await SupabaseClient.shared.rpcList("invite_preview", ["p_code": code])
        return rows.first
    }

    static func accept(_ code: String) async throws -> Membership {
        try await SupabaseClient.shared.rpc("accept_invite", ["p_code": code])
    }
}
