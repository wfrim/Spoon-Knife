import BackgroundTasks
import SwiftUI

@main
struct ApartmentLineApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PresenceSpikeView()
                .environmentObject(PresenceStore.shared)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await PresenceStore.shared.heartbeat() }
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Background launches for a geofence crossing come through here with no
        // UI; starting the store re-attaches to CLMonitor so the event is delivered.
        Heartbeat.register()
        PresenceStore.shared.start()
        Heartbeat.schedule()
        return true
    }
}

/// Background App Refresh keeps "home" from expiring on the server (24 h TTL)
/// for someone who hasn't crossed the geofence in a while. iOS decides the
/// actual timing; AppConfig.heartbeatInterval is only the earliest start.
enum Heartbeat {
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppConfig.heartbeatTaskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            schedule()
            let work = Task { @MainActor in
                await PresenceStore.shared.heartbeat()
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: AppConfig.heartbeatTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: AppConfig.heartbeatInterval)
        try? BGTaskScheduler.shared.submit(request)
    }
}
