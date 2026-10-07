import CoreLocation

/// Wraps the iOS 17 `CLMonitor` with a single circular condition around home.
///
/// CLMonitor persists its conditions. When iOS relaunches the app in the
/// background for a boundary crossing, re-creating the monitor with the same
/// name and iterating `events` is what delivers that crossing, so `start` must
/// run on every launch (AppDelegate does this).
@MainActor
final class HomeGeofence {
    static let monitorName = "ApartmentLineHome"
    static let conditionID = "home"

    private var monitor: CLMonitor?
    private var listenTask: Task<Void, Never>?

    private func instance() async -> CLMonitor {
        if let monitor { return monitor }
        let created = await CLMonitor(Self.monitorName)
        monitor = created
        return created
    }

    /// Begins delivering crossings. Safe to call more than once.
    func start(onChange: @escaping (PresenceState, Date) -> Void) {
        guard listenTask == nil else { return }
        listenTask = Task {
            let monitor = await instance()
            do {
                for try await event in await monitor.events where event.identifier == Self.conditionID {
                    if let state = Self.presence(for: event.state) {
                        onChange(state, event.date)
                    }
                }
            } catch {
                // The sequence only ends if monitoring is torn down; the next launch restarts it.
            }
            listenTask = nil
        }
    }

    /// Replaces the home circle. Re-adding an identifier replaces its condition.
    func setHome(_ home: HomeLocation?) async {
        let monitor = await instance()
        guard let home else {
            await monitor.remove(Self.conditionID)
            return
        }
        let condition = CLMonitor.CircularGeographicCondition(center: home.coordinate, radius: home.radius)
        await monitor.add(condition, identifier: Self.conditionID)
    }

    /// What the monitor currently believes, for heartbeats.
    func currentState() async -> PresenceState? {
        guard let record = await instance().record(for: Self.conditionID) else { return nil }
        return Self.presence(for: record.lastEvent.state)
    }

    private static func presence(for state: CLMonitor.Event.State) -> PresenceState? {
        switch state {
        case .satisfied: return .home
        case .unsatisfied: return .away
        default: return nil  // .unknown / .unmonitored carry no information
        }
    }
}
