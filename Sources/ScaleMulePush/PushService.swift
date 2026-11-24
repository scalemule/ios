import Foundation
import ScaleMuleCore

/// A server registration, not the APNs device token. Safe to retain for cleanup.
public struct PushRegistration: Decodable, Sendable, Equatable {
    public let id: String
    public let userId: String?
    public let platform: String
    public let isActive: Bool
    public let notificationsEnabled: Bool
    enum CodingKeys: String, CodingKey {
        case id, platform
        case userId = "user_id", isActive = "is_active", notificationsEnabled = "notifications_enabled"
    }
}

/// Device registration only. Sending notifications and APNs signing keys belong on the server.
public final class PushService: ServiceModule, @unchecked Sendable {
    public let client: HTTPClient
    public required init(client: HTTPClient) { self.client = client }
    public convenience init(app: ScaleMuleApp) { self.init(client: app.client) }

    /// Keep the token's byte length intact; Apple can change it.
    public static func tokenString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public func register(deviceToken: Data, userId: String, appVersion: String? = nil,
                         osVersion: String? = nil) async -> ApiResponse<PushRegistration> {
        guard let session = await client.sessionManager.sessionToken else {
            return .failure(ApiError(code: .unauthorized, message: "Sign in to enable notifications.", statusCode: 401))
        }
        return await register(deviceToken: deviceToken, userId: userId, session: session,
                              appVersion: appVersion, osVersion: osVersion)
    }

    func register(deviceToken: Data, userId: String, session: String, appVersion: String?,
                  osVersion: String?) async -> ApiResponse<PushRegistration> {
        guard !deviceToken.isEmpty else {
            return .failure(ApiError(code: .unknown, message: "Apple returned an empty device token."))
        }
        guard let expectedUser = UUID(uuidString: userId) else {
            return .failure(ApiError(code: .unknown, message: "Invalid signed-in user ID."))
        }
        // The server derives the owner from the session. A plain iOS registration
        // switches off this token's previous account bindings; do not send a user list.
        var body: [String: Any] = ["token": Self.tokenString(deviceToken), "platform": "ios",
            "registration_source": "scalemule-ios"]
        if let appVersion { body["app_version"] = appVersion }
        if let osVersion { body["os_version"] = osVersion }
        let result: ApiResponse<PushRegistration> = await client.request(RequestOptions(method: .post, path: "/v1/communication/push/register",
            body: body, credential: .none, retryable: false, headers: ["Authorization": "Bearer \(session)"]))
        if case .success(let registration) = result,
           registration.userId.flatMap(UUID.init(uuidString:)) != expectedUser {
            _ = await unregister(id: registration.id, session: session)
            return .failure(ApiError(code: .forbidden, message: "The signed-in account changed. Please try again.", statusCode: 403))
        }
        return result
    }

    public func unregister(id: String) async -> ApiResponse<Void> {
        guard let session = await client.sessionManager.sessionToken else {
            return .failure(ApiError(code: .unauthorized, message: "Sign in first.", statusCode: 401))
        }
        return await unregister(id: id, session: session)
    }

    /// Prefer a refreshed session for the same account. Keep the original
    /// session available during an account switch; a new account must never
    /// be used to authorize cleanup of the previous account's device.
    func unregister(id: String, userId: String, originalSession: String) async -> ApiResponse<Void> {
        var session = originalSession
        if let remembered = await client.sessionManager.rememberedUser(), remembered.id == userId,
           let latest = await client.sessionManager.sessionToken {
            session = latest
        }
        let result = await unregister(id: id, session: session)
        // A concurrent sign-in may replace credentials between the two reads.
        // The server's ownership check rejects that session; retry the binding's.
        if result.error?.statusCode == 403, session != originalSession {
            return await unregister(id: id, session: originalSession)
        }
        return result
    }

    func unregister(id: String, session: String) async -> ApiResponse<Void> {
        guard let uuid = UUID(uuidString: id) else {
            return .failure(ApiError(code: .unknown, message: "Invalid push registration ID."))
        }
        let result = await client.requestVoid(RequestOptions(method: .delete,
            path: "/v1/communication/push/tokens/by-id/\(uuid.uuidString.lowercased())",
            credential: .none, retryable: false, headers: ["Authorization": "Bearer \(session)"]))
        switch result {
        case .success: return .success(())
        case .failure(let error) where error.statusCode == 404: return .success(())
        case .failure(let error): return .failure(error)
        }
    }

    func setEnabled(_ enabled: Bool, id: String, session: String) async -> ApiResponse<Void> {
        guard let uuid = UUID(uuidString: id) else {
            return .failure(ApiError(code: .unknown, message: "Invalid push registration ID."))
        }
        let result = await client.requestVoid(RequestOptions(method: .put,
            path: "/v1/communication/push/tokens/by-id/\(uuid.uuidString.lowercased())/notifications",
            body: ["enabled": enabled], credential: .none, retryable: false,
            headers: ["Authorization": "Bearer \(session)"]))
        switch result {
        case .success: return .success(())
        case .failure(let error): return .failure(error)
        }
    }
}
