import AVFoundation
import Foundation

/// Records the caller's message after the beep (max 60 s) and uploads it to
/// Storage at voicemails/<home>/<call>.m4a.
@MainActor
final class VoicemailRecorder {
    static let maxSeconds: TimeInterval = 60
    private var recorder: AVAudioRecorder?
    private var startedAt: Date?

    private var fileURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("voicemail.m4a")
    }

    func start() throws {
        try? FileManager.default.removeItem(at: fileURL)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.record(forDuration: Self.maxSeconds)
        self.recorder = recorder
        startedAt = Date()
    }

    /// Stops recording and sends it. Hanging up sends too (plan: hanging up = send).
    func finish(callID: UUID, homeID: UUID) async throws {
        guard let recorder, let startedAt else { return }
        recorder.stop()
        self.recorder = nil
        let seconds = min(Date().timeIntervalSince(startedAt), Self.maxSeconds)
        guard seconds >= 1 else { return }  // a hang-up at the beep isn't a message
        let path = try await SupabaseClient.shared.upload(
            bucket: "voicemails", path: "\(homeID.uuidString.lowercased())/\(callID.uuidString.lowercased()).m4a",
            file: fileURL, contentType: "audio/mp4")
        try await CallService.leaveVoicemail(callID, audioPath: path, seconds: seconds.rounded())
    }

    func discard() {
        recorder?.stop()
        recorder = nil
        try? FileManager.default.removeItem(at: fileURL)
    }
}
