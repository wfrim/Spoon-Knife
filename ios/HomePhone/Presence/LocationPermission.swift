import CoreLocation
import UIKit

/// Walks the user to "Always": When In Use first, then the upgrade prompt.
@MainActor
final class LocationPermission: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var status: CLAuthorizationStatus
    @Published private(set) var preciseLocation: Bool

    private let manager: CLLocationManager

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        status = manager.authorizationStatus
        preciseLocation = manager.accuracyAuthorization == .fullAccuracy
        super.init()
        manager.delegate = self
    }

    var isAlways: Bool { status == .authorizedAlways }

    var summary: String {
        switch status {
        case .authorizedAlways: return preciseLocation ? "Always" : "Always, but Precise Location is off"
        case .authorizedWhenInUse: return "While Using — needs Always"
        case .denied, .restricted: return "Off"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    func request() {
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let precise = manager.accuracyAuthorization == .fullAccuracy
        Task { @MainActor in
            self.status = status
            self.preciseLocation = precise
        }
    }

    /// A good-enough fix for "use my current location" when setting home.
    static func currentLocation() async throws -> CLLocation? {
        var best: CLLocation?
        var updates = 0
        for try await update in CLLocationUpdate.liveUpdates() {
            guard let location = update.location else { continue }
            updates += 1
            if best == nil || location.horizontalAccuracy < best!.horizontalAccuracy { best = location }
            if location.horizontalAccuracy <= 30 || updates >= 10 { break }
        }
        return best
    }
}
