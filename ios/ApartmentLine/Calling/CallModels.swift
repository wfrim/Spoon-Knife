import Foundation

enum CallState: String, Decodable {
    case ringing, active, ended, missed, voicemail
}

/// A public.calls row (the fields the app uses).
struct CallRow: Decodable, Equatable {
    let id: UUID
    let apartmentId: UUID?
    let targetUserId: UUID?
    let callerId: UUID
    let state: CallState
    let answeredBy: UUID?
    let ringUntil: Date
    let endReason: String?
}

/// What the ringing phone shows, from the VoIP push (see place-call/handler.ts).
struct IncomingCallInfo {
    let callID: UUID
    let callerName: String
    let homeName: String?

    init?(payload: [AnyHashable: Any]) {
        guard let raw = payload["call_id"] as? String, let id = UUID(uuidString: raw) else { return nil }
        callID = id
        callerName = payload["caller_name"] as? String ?? "Someone"
        homeName = payload["home_name"] as? String
    }

    /// "Kim · The Burrow" for home calls, "Kim" for direct calls.
    var displayName: String {
        if let homeName { return "\(callerName) · \(homeName)" }
        return callerName
    }
}

struct RoomAccess: Decodable {
    let url: String
    let token: String
}

struct PlaceCallResponse: Decodable {
    let call: CallRow
    let rang: Int
    let room: RoomAccess?
    let note: String?
}
