import Foundation
import UIKit

/// Owns this phone's presence: listens to the geofence, takes manual overrides
/// and heartbeats, queues every report, and delivers them to `report_presence`.
@MainActor
final class PresenceStore: ObservableObject {
    static let shared = PresenceStore()

    @Published private(set) var home: HomeLocation?
    @Published private(set) var serverState: PresenceState = .unknown
    @Published private(set) var serverSource: PresenceSource?
    @Published private(set) var serverUpdatedAt: Date?
    @Published private(set) var history: [PresenceReport] = []
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastError: String?

    private let geofence = HomeGeofence()
    private let homeFile = JSONFile<HomeLocation>("home.json")
    private let outboxFile = JSONFile<[PresenceReport]>("presence-outbox.json")
    private let historyFile = JSONFile<[PresenceReport]>("presence-history.json")
    private var outbox: [PresenceReport]
    private var isFlushing = false
    private var started = false

    private static let deviceIDKey = "device.id"
    private static let deviceOwnerKey = "device.owner"

    private init() {
        home = homeFile.load()
        outbox = outboxFile.load() ?? []
        history = historyFile.load() ?? []
        pendingCount = outbox.count
    }

    // MARK: Lifecycle

    /// Call on every launch, including background relaunches for a crossing.
    func start() {
        guard !started else { return }
        started = true
        geofence.start { [weak self] state, date in
            self?.enqueue(PresenceReport(state: state, source: .geofence, reportedAt: date))
        }
        Task { await flush() }
    }

    func setHome(_ newHome: HomeLocation?) async {
        home = newHome
        if let newHome { homeFile.save(newHome) } else { try? FileManager.default.removeItem(at: homeFile.url) }
        await geofence.setHome(newHome)
    }

    // MARK: Reports

    func setManual(_ state: PresenceState) {
        enqueue(PresenceReport(state: state, source: .manual, reportedAt: Date()))
    }

    /// Re-confirms the geofence's current state so the server's 24 h expiry
    /// doesn't drop someone who has simply stayed home.
    func heartbeat() async {
        if let state = await geofence.currentState() {
            enqueue(PresenceReport(state: state, source: .heartbeat, reportedAt: Date()))
        }
        await flush()
    }

    /// Ground truth for the Phase 0 gate.
    func recordCheck(actual: PresenceState, note: String) async {
        await flush()
        do {
            let deviceID = try await ensureDevice()
            let _: PresenceCheckRow = try await SupabaseClient.shared.rpc(
                "record_presence_check", CheckParams(deviceID: deviceID, actual: actual, note: note))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func enqueue(_ report: PresenceReport) {
        outbox.append(report)
        outboxFile.save(outbox)
        pendingCount = outbox.count
        Task { await flush() }
    }

    /// Sends queued reports in order. Runs under a background task so a
    /// geofence relaunch gets enough time to finish the request.
    func flush() async {
        guard !isFlushing, !outbox.isEmpty else { return }
        isFlushing = true
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "presence") {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        defer {
            isFlushing = false
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }

        do {
            let deviceID = try await ensureDevice()
            while var report = outbox.first {
                let row: DeviceRow = try await SupabaseClient.shared.rpc(
                    "report_presence", ReportParams(deviceID: deviceID, report: report))
                outbox.removeFirst()
                outboxFile.save(outbox)
                report.deliveredAt = Date()
                remember(report)
                apply(row)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        pendingCount = outbox.count
    }

    private func apply(_ row: DeviceRow) {
        serverState = row.presence
        serverSource = row.presenceSource
        serverUpdatedAt = row.presenceAt
    }

    private func remember(_ report: PresenceReport) {
        history.insert(report, at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        historyFile.save(history)
    }

    // MARK: Device registration

    /// Saves this phone's PushKit token so calls can ring it. Nil clears it.
    func setVoipToken(_ token: String?) async {
        do {
            let deviceID = try await ensureDevice()
            try await SupabaseClient.shared.update("devices", where: "id=eq.\(deviceID.uuidString)",
                                                   VoipTokenPatch(voipToken: token))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// One devices row per install, re-created if the auth user changes.
    func ensureDevice() async throws -> UUID {
        let session = try await SupabaseClient.shared.ensureSession()
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.deviceIDKey), let id = UUID(uuidString: raw),
           defaults.string(forKey: Self.deviceOwnerKey) == session.userID.uuidString {
            return id
        }
        let row: DeviceRow = try await SupabaseClient.shared.insert(
            into: "devices", ["name": "\(UIDevice.current.model) \(UIDevice.current.systemVersion)"])
        defaults.set(row.id.uuidString, forKey: Self.deviceIDKey)
        defaults.set(session.userID.uuidString, forKey: Self.deviceOwnerKey)
        return row.id
    }

    /// Lets testers tell their phones apart in the Phase 0 report.
    func setTesterName(_ name: String) async {
        do {
            let session = try await SupabaseClient.shared.ensureSession()
            try await SupabaseClient.shared.update("users", where: "id=eq.\(session.userID.uuidString)",
                                                   ["display_name": name])
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}

// MARK: - RPC payloads

private struct VoipTokenPatch: Encodable {
    let voipToken: String?

    enum CodingKeys: String, CodingKey { case voipToken = "voip_token" }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(voipToken, forKey: .voipToken)  // explicit null clears it
    }
}

private struct ReportParams: Encodable {
    let deviceID: UUID
    let report: PresenceReport

    enum CodingKeys: String, CodingKey {
        case deviceID = "p_device_id", state = "p_state", source = "p_source"
        case reportedAt = "p_reported_at", detail = "p_detail"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(report.state, forKey: .state)
        try container.encode(report.source, forKey: .source)
        try container.encode(report.reportedAt, forKey: .reportedAt)
        try container.encode(report.detail, forKey: .detail)
    }
}

private struct CheckParams: Encodable {
    let deviceID: UUID
    let actual: PresenceState
    let note: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "p_device_id", actual = "p_actual", note = "p_note"
    }
}

private struct PresenceCheckRow: Decodable {
    let id: Int
}
