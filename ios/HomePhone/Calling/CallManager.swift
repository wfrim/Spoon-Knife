import AudioToolbox
import AVFoundation
import CallKit
import Foundation
import PushKit

/// CallKit + PushKit. Incoming: a VoIP push must be reported to CallKit right
/// away (iOS stops waking apps that don't), then the phone watches the call row
/// and stops ringing when someone else answers or it rings out. Outgoing:
/// place-call, wait in the LiveKit room, and fall through to voicemail.
@MainActor
final class CallManager: NSObject, ObservableObject {
    static let shared = CallManager()

    enum Phase: Equatable {
        case idle, ringing, connected, leavingMessage, ended(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastError: String?

    var isBusy: Bool {
        switch phase {
        case .ringing, .connected, .leavingMessage: return true
        case .idle, .ended: return false
        }
    }

    private let provider: CXProvider
    private let controller = CXCallController()
    private var registry: PKPushRegistry?

    /// CallKit's UUID for each server call id, both directions.
    private var callIDs: [UUID: UUID] = [:]
    private var outgoingHome: [UUID: UUID] = [:]
    private var room: VoiceRoom?
    private var recorder: VoicemailRecorder?
    private var watcher: Task<Void, Never>?

    override private init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = true
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)  // main queue
    }

    /// Call at launch: registers for VoIP pushes.
    func start() {
        guard registry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    // MARK: Outgoing

    func call(home apartmentID: UUID, named name: String, asHome: UUID? = nil) {
        let uuid = UUID()
        outgoingHome[uuid] = apartmentID
        pendingAsHome[uuid] = asHome
        let handle = CXHandle(type: .generic, value: name)
        let action = CXStartCallAction(call: uuid, handle: handle)
        controller.request(CXTransaction(action: action)) { [weak self] error in
            if let error { Task { @MainActor in self?.lastError = error.localizedDescription } }
        }
    }

    private var pendingAsHome: [UUID: UUID] = [:]

    func hangUp() {
        guard let uuid = callIDs.keys.first else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
    }

    private func placeCall(uuid: UUID, apartmentID: UUID) async {
        do {
            let placed = try await CallService.placeCall(apartmentID: apartmentID, asHome: pendingAsHome[uuid])
            callIDs[uuid] = placed.call.id
            provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
            if let access = placed.room {
                let room = VoiceRoom()
                self.room = room
                try await room.connect(access)  // wait in the room so an answer connects instantly
            }
            await follow(placed.call, uuid: uuid, outgoing: true)
        } catch {
            lastError = error.localizedDescription
            provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
            await cleanUp(uuid)
        }
    }

    // MARK: Watching a call

    /// Polls the call row every 2 s (Realtime would be nicer; see backlog) and
    /// drives CallKit from what the server says.
    private func follow(_ initial: CallRow, uuid: UUID, outgoing: Bool) async {
        watcher?.cancel()
        watcher = Task { [weak self] in
            var call = initial
            var rungOut = false
            while !Task.isCancelled {
                guard let self else { return }
                switch call.state {
                case .ringing:
                    phase = .ringing
                    if outgoing, !rungOut, call.ringUntil <= Date() {
                        rungOut = true
                        if let settled = try? await CallService.ringOut(call.id) { call = settled; continue }
                    }
                case .active:
                    if outgoing, phase != .connected {
                        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
                    } else if !outgoing, call.answeredBy != (await SupabaseClient.shared.currentUserID) {
                        provider.reportCall(with: uuid, endedAt: nil, reason: .answeredElsewhere)
                        await cleanUp(uuid)
                        return
                    }
                    phase = .connected
                case .voicemail:
                    if outgoing {
                        await startVoicemail(call, uuid: uuid)
                    } else {
                        provider.reportCall(with: uuid, endedAt: nil, reason: .unanswered)
                        await cleanUp(uuid)
                    }
                    return
                case .missed, .ended:
                    provider.reportCall(with: uuid, endedAt: nil, reason: call.state == .missed ? .unanswered : .remoteEnded)
                    phase = .ended(call.state == .missed ? "No answer" : "Call ended")
                    await cleanUp(uuid)
                    return
                }
                try? await Task.sleep(for: .seconds(2))
                if let fresh = try? await CallService.current(call.id) { call = fresh }
            }
        }
    }

    // MARK: Voicemail

    /// Nobody picked up: the caller hears the beep and records. Hanging up sends.
    private func startVoicemail(_ call: CallRow, uuid: UUID) async {
        phase = .leavingMessage
        await room?.disconnect()
        room = nil
        AudioServicesPlaySystemSound(1052)  // the beep; the home's greeting plays first once it's stored
        let recorder = VoicemailRecorder()
        do {
            try recorder.start()
            self.recorder = recorder
        } catch {
            lastError = "Couldn't record: \(error.localizedDescription)"
            controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
        }
    }

    private func cleanUp(_ uuid: UUID) async {
        watcher?.cancel()
        watcher = nil
        await room?.disconnect()
        room = nil
        recorder?.discard()
        recorder = nil
        callIDs[uuid] = nil
        outgoingHome[uuid] = nil
        pendingAsHome[uuid] = nil
        if case .ended = phase {} else { phase = .idle }
    }
}

// MARK: - CXProviderDelegate

extension CallManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            for uuid in Array(callIDs.keys) { Task { await cleanUp(uuid) } }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        MainActor.assumeIsolated {
            guard let apartmentID = outgoingHome[action.callUUID] else { return action.fail() }
            action.fulfill()
            Task { await placeCall(uuid: action.callUUID, apartmentID: apartmentID) }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        MainActor.assumeIsolated {
            guard let callID = callIDs[action.callUUID] else { return action.fail() }
            Task {
                do {
                    guard try await CallService.answer(callID) != nil else {
                        // Someone else got there first.
                        action.fail()
                        provider.reportCall(with: action.callUUID, endedAt: nil, reason: .answeredElsewhere)
                        await cleanUp(action.callUUID)
                        return
                    }
                    let room = VoiceRoom()
                    self.room = room
                    try await room.connect(try await CallService.roomToken(callID))
                    phase = .connected
                    action.fulfill()
                } catch {
                    lastError = error.localizedDescription
                    action.fail()
                }
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated {
            let uuid = action.callUUID
            guard let callID = callIDs[uuid] else { return action.fulfill() }
            Task {
                if case .leavingMessage = phase, let recorder, let homeID = outgoingHome[uuid] {
                    do { try await recorder.finish(callID: callID, homeID: homeID) } catch {
                        lastError = "Message not sent: \(error.localizedDescription)"
                    }
                    self.recorder = nil
                    phase = .ended("Message sent")
                } else {
                    _ = try? await CallService.end(callID)
                    phase = .ended("Call ended")
                }
                await cleanUp(uuid)
                action.fulfill()
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MainActor.assumeIsolated {
            let muted = action.isMuted
            Task { await room?.setMuted(muted) }
            action.fulfill()
        }
    }
}

// MARK: - PKPushRegistryDelegate

extension CallManager: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in await PresenceStore.shared.setVoipToken(token) }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        Task { @MainActor in await PresenceStore.shared.setVoipToken(nil) }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType, completion: @escaping () -> Void
    ) {
        MainActor.assumeIsolated {
            // Report first, always: iOS requires every VoIP push to show a call.
            let uuid = UUID()
            let info = IncomingCallInfo(payload: payload.dictionaryPayload)
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: info?.callID.uuidString ?? "unknown")
            update.localizedCallerName = info?.displayName ?? "Home Phone"
            update.hasVideo = false
            update.supportsHolding = false
            update.supportsDTMF = false
            provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
                Task { @MainActor in
                    defer { completion() }
                    guard let self else { return }
                    guard error == nil, let info else {
                        // Bad payload (or Do Not Disturb): end the call we just showed.
                        self.provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
                        return
                    }
                    self.callIDs[uuid] = info.callID
                    if let call = try? await CallService.current(info.callID) {
                        await self.follow(call, uuid: uuid, outgoing: false)
                    }
                }
            }
        }
    }
}
