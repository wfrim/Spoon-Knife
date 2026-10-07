import Foundation

/// Invite links look like https://apartmentline.app/j/<code>. Shared by the
/// app and the App Clip.
enum InviteLink {
    static let host = "apartmentline.app"

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

/// Just enough of the home's theme for the App Clip and invite screens.
struct InviteTheme {
    let background: UInt32
    let accent: UInt32
    let onAccent: UInt32
    let ink: UInt32
    let rounded: Bool
    let serif: Bool

    static func named(_ key: String) -> InviteTheme {
        switch key {
        case "simple-ember": return .init(background: 0xF6F7FB, accent: 0xC2410C, onAccent: 0xFFFFFF, ink: 0x14172B, rounded: false, serif: false)
        case "simple-forest": return .init(background: 0xF6F7FB, accent: 0x166534, onAccent: 0xFFFFFF, ink: 0x14172B, rounded: false, serif: false)
        case "simple-plum": return .init(background: 0xF6F7FB, accent: 0x7E22CE, onAccent: 0xFFFFFF, ink: 0x14172B, rounded: false, serif: false)
        case "sticker-bubblegum": return .init(background: 0xFFEFE3, accent: 0x7BE0A3, onAccent: 0x2B2140, ink: 0x2B2140, rounded: true, serif: false)
        case "sticker-pool": return .init(background: 0xE3F6F5, accent: 0x6EE7B7, onAccent: 0x12343B, ink: 0x12343B, rounded: true, serif: false)
        case "sticker-night": return .init(background: 0x241A3D, accent: 0x7BE0A3, onAccent: 0x0F0A1C, ink: 0xFFF7EE, rounded: true, serif: false)
        case "rotary-mustard": return .init(background: 0xF4E7CC, accent: 0x4A2C1A, onAccent: 0xF4E7CC, ink: 0x3A2213, rounded: false, serif: true)
        case "rotary-avocado": return .init(background: 0xEEF0DD, accent: 0x2F3A1A, onAccent: 0xEEF0DD, ink: 0x26301A, rounded: false, serif: true)
        case "rotary-rust": return .init(background: 0xF7E4D7, accent: 0x3B1F14, onAccent: 0xF7E4D7, ink: 0x3B1F14, rounded: false, serif: true)
        case "rotary-bakelite": return .init(background: 0xEFE6D2, accent: 0x1F1C1A, onAccent: 0xEFE6D2, ink: 0x1F1C1A, rounded: false, serif: true)
        default: return .init(background: 0xF6F7FB, accent: 0x1D4ED8, onAccent: 0xFFFFFF, ink: 0x14172B, rounded: false, serif: false)
        }
    }
}
