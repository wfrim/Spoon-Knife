import Foundation

/// Where the app is: still loading, onboarding, or living in a home.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case onboarding
        case home(Home)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading

    var home: Home? {
        if case .home(let home) = phase { return home }
        return nil
    }

    /// Looks up your home. If you have one, its circle becomes your geofence.
    func refresh() async {
        do {
            if let home = try await HomeService.currentHome() {
                phase = .home(home)
                if PresenceStore.shared.home != home.location {
                    await PresenceStore.shared.setHome(home.location)
                }
            } else {
                phase = .onboarding
            }
        } catch {
            if case .home = phase { return }  // keep showing the home when offline
            phase = .failed(error.localizedDescription)
        }
    }

    func setTheme(_ key: String) async {
        guard let home else { return }
        phase = .home(Home(id: home.id, name: home.name, handle: home.handle, city: home.city, theme: key,
                           statusLine: home.statusLine, homeLat: home.homeLat, homeLng: home.homeLng, radiusM: home.radiusM))
        try? await HomeService.setTheme(home.id, key)
    }
}
