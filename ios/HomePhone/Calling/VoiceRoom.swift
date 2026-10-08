import Foundation
import LiveKit

/// The audio side of a call: one LiveKit room, microphone only.
@MainActor
final class VoiceRoom {
    private let room = Room()
    private(set) var isConnected = false

    func connect(_ access: RoomAccess) async throws {
        guard !isConnected else { return }
        try await room.connect(url: access.url, token: access.token)
        isConnected = true
        try await room.localParticipant.setMicrophone(enabled: true)
    }

    func setMuted(_ muted: Bool) async {
        _ = try? await room.localParticipant.setMicrophone(enabled: !muted)
    }

    func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        await room.disconnect()
    }
}
