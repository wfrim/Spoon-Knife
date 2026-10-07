import Foundation

/// Minimal Supabase REST client: anonymous auth (Phase 0; Sign in with Apple
/// arrives in Phase 1), PostgREST RPC, insert and update.
actor SupabaseClient {
    static let shared = SupabaseClient()

    struct Session: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var userID: UUID
    }

    enum ClientError: LocalizedError {
        case http(status: Int, body: String)

        var errorDescription: String? {
            switch self {
            case let .http(status, body): return "Server error \(status): \(body.prefix(200))"
            }
        }
    }

    private static let sessionKey = "supabase.session"
    private var session: Session?
    private var renewal: Task<Session, Error>?

    private init() {
        if let data = Keychain.data(for: Self.sessionKey) {
            session = try? JSONDecoder().decode(Session.self, from: data)
        }
    }

    var currentUserID: UUID? { session?.userID }

    // MARK: Auth

    /// Returns a valid session, refreshing or (first launch only) signing up anonymously.
    @discardableResult
    func ensureSession() async throws -> Session {
        if let session, session.expiresAt.timeIntervalSinceNow > 60 { return session }
        // Single-flight: concurrent callers on first launch must not each create a user.
        if let renewal { return try await renewal.value }
        let task = Task { try await renewSession() }
        renewal = task
        defer { renewal = nil }
        return try await task.value
    }

    private func renewSession() async throws -> Session {
        if let session {
            do {
                return store(try await authRequest(path: "auth/v1/token?grant_type=refresh_token",
                                                   body: ["refresh_token": session.refreshToken]))
            } catch ClientError.http(let status, _) where (400..<500).contains(status) {
                // Refresh token revoked; fall through to a fresh anonymous user.
            }
        }
        // Requires "Allow anonymous sign-ins" in Supabase → Authentication → Providers.
        return store(try await authRequest(path: "auth/v1/signup", body: [:]))
    }

    private struct AuthResponse: Decodable {
        struct User: Decodable { let id: UUID }
        let accessToken: String
        let refreshToken: String
        let expiresIn: Double
        let user: User
    }

    private func authRequest(path: String, body: [String: String]) async throws -> Session {
        var request = URLRequest(url: URL(string: path, relativeTo: AppConfig.supabaseURL)!)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        let response: AuthResponse = try await send(request, token: nil)
        return Session(accessToken: response.accessToken,
                       refreshToken: response.refreshToken,
                       expiresAt: Date().addingTimeInterval(response.expiresIn),
                       userID: response.user.id)
    }

    private func store(_ new: Session) -> Session {
        session = new
        Keychain.set(try? JSONEncoder().encode(new), for: Self.sessionKey)
        return new
    }

    // MARK: PostgREST

    /// POST /rest/v1/rpc/<name>. Functions returning one row decode as an object.
    func rpc<Params: Encodable, Response: Decodable>(_ name: String, _ params: Params) async throws -> Response {
        try await rest(method: "POST", path: "rest/v1/rpc/\(name)", body: params, single: true)
    }

    /// Inserts one row and returns it.
    func insert<Row: Encodable, Response: Decodable>(into table: String, _ row: Row) async throws -> Response {
        try await rest(method: "POST", path: "rest/v1/\(table)", body: row, single: true,
                       headers: ["Prefer": "return=representation"])
    }

    /// PATCH rows matching `filter` (PostgREST syntax, e.g. "id=eq.<uuid>").
    func update<Row: Encodable>(_ table: String, where filter: String, _ row: Row) async throws {
        let _: [EmptyRow] = try await rest(method: "PATCH", path: "rest/v1/\(table)?\(filter)", body: row,
                                           single: false, headers: ["Prefer": "return=minimal"])
    }

    private struct EmptyRow: Decodable {}

    private func rest<Body: Encodable, Response: Decodable>(
        method: String, path: String, body: Body, single: Bool, headers: [String: String] = [:]
    ) async throws -> Response {
        let token = try await ensureSession().accessToken
        var request = URLRequest(url: URL(string: path, relativeTo: AppConfig.supabaseURL)!)
        request.httpMethod = method
        request.httpBody = try Self.encoder.encode(body)
        if single { request.setValue("application/vnd.pgrst.object+json", forHTTPHeaderField: "Accept") }
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        return try await send(request, token: token)
    }

    private func send<Response: Decodable>(_ request: URLRequest, token: String?) async throws -> Response {
        var request = request
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token ?? AppConfig.supabaseAnonKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ClientError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        // "return=minimal" responses have no body.
        return try Self.decoder.decode(Response.self, from: data.isEmpty ? Data("[]".utf8) : data)
    }

    // MARK: Coding

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // Postgres sends "2026-10-07T02:21:00.123456+00:00"; drop the fraction
        // rather than depend on how many digits ISO8601DateFormatter accepts.
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let trimmed = raw.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
            guard let date = ISO8601DateFormatter().date(from: trimmed) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised date \(raw)")
            }
            return date
        }
        return decoder
    }()
}
