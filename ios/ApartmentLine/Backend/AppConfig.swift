import Foundation

enum AppConfig {
    /// Filled from Config/Secrets.xcconfig via Info.plist.
    static let supabaseURL: URL = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String,
              let url = URL(string: raw), url.host != nil else {
            fatalError("SupabaseURL is missing. Copy ios/Config/Secrets.example.xcconfig to Secrets.xcconfig and fill it in.")
        }
        return url
    }()

    static let supabaseAnonKey: String = {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String, !key.isEmpty else {
            fatalError("SupabaseAnonKey is missing. Copy ios/Config/Secrets.example.xcconfig to Secrets.xcconfig and fill it in.")
        }
        return key
    }()

    /// Must match BGTaskSchedulerPermittedIdentifiers in project.yml.
    static let heartbeatTaskID = "app.apartmentline.heartbeat"
    static let heartbeatInterval: TimeInterval = 4 * 60 * 60
}
