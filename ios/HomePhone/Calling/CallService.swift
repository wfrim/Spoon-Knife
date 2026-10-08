import Foundation

/// Server calls for one phone call. Everything that decides who may call whom
/// lives in the database; this is just the plumbing.
enum CallService {
    private static var client: SupabaseClient { .shared }

    static func placeCall(apartmentID: UUID? = nil, userID: UUID? = nil, asHome: UUID? = nil) async throws -> PlaceCallResponse {
        try await client.invoke("place-call", PlaceCallBody(apartmentId: apartmentID, userId: userID, asHome: asHome))
    }

    /// First answer wins: nil means someone else picked up first.
    static func answer(_ callID: UUID) async throws -> CallRow? {
        let rows: [CallRow] = try await client.rpcList("answer_call", ["p_call_id": callID])
        return rows.first
    }

    static func roomToken(_ callID: UUID) async throws -> RoomAccess {
        try await client.invoke("call-token", ["call_id": callID])
    }

    static func current(_ callID: UUID) async throws -> CallRow? {
        let rows: [CallRow] = try await client.select("calls?id=eq.\(callID.uuidString)&select=*")
        return rows.first
    }

    @discardableResult
    static func ringOut(_ callID: UUID) async throws -> CallRow {
        try await client.rpc("ring_out", RingOutParams(callID: callID, nobodyHome: false))
    }

    @discardableResult
    static func end(_ callID: UUID) async throws -> CallRow {
        try await client.rpc("end_call", ["p_call_id": callID])
    }

    static func leaveVoicemail(_ callID: UUID, audioPath: String, seconds: Double) async throws {
        let _: MessageRow = try await client.rpc(
            "leave_voicemail", VoicemailParams(callID: callID, audioURL: audioPath, duration: seconds))
    }
}

private struct PlaceCallBody: Encodable {
    let apartmentId: UUID?
    let userId: UUID?
    let asHome: UUID?

    enum CodingKeys: String, CodingKey {
        case apartmentId = "apartment_id", userId = "user_id", asHome = "as_home"
    }
}

private struct RingOutParams: Encodable {
    let callID: UUID
    let nobodyHome: Bool
    enum CodingKeys: String, CodingKey { case callID = "p_call_id", nobodyHome = "p_nobody_home" }
}

private struct VoicemailParams: Encodable {
    let callID: UUID
    let audioURL: String
    let duration: Double
    enum CodingKeys: String, CodingKey { case callID = "p_call_id", audioURL = "p_audio_url", duration = "p_duration_s" }
}

private struct MessageRow: Decodable { let id: UUID }
