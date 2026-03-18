import Foundation
import ScaleMuleCore

public final class AuthService: ServiceModule, @unchecked Sendable {
    public let client: HTTPClient
    public let sessions: AuthSessionsSubService
    public let devices: AuthDevicesSubService
    public let loginHistory: AuthLoginHistorySubService
    public let mfa: AuthMFASubService

    public required init(client: HTTPClient) {
        self.client = client
        self.sessions = AuthSessionsSubService(client: client)
        self.devices = AuthDevicesSubService(client: client)
        self.loginHistory = AuthLoginHistorySubService(client: client)
        self.mfa = AuthMFASubService(client: client)
    }

    // MARK: - A02: Register

    public func register(
        email: String,
        password: String,
        name: String? = nil,
        username: String? = nil,
        phone: String? = nil
    ) async -> ApiResponse<RegisterResult> {
        var body: [String: Any] = [
            "email": email,
            "password": password,
        ]
        if let name { body["full_name"] = name }
        if let username { body["username"] = username }
        if let phone { body["phone"] = phone }

        return await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/register",
            body: body,
            credential: .none
        ))
    }

    // MARK: - A05: Login

    public func login(
        email: String,
        password: String,
        rememberMe: Bool? = nil,
        deviceFingerprint: String? = nil
    ) async -> ApiResponse<LoginResult> {
        var body: [String: Any] = [
            "email": email,
            "password": password,
        ]
        if let rememberMe { body["remember_me"] = rememberMe }
        if let deviceFingerprint { body["device_fingerprint"] = deviceFingerprint }

        return await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/login",
            body: body,
            credential: .none
        ))
    }

    // MARK: - A06: Logout

    public func logout() async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .post,
            path: "/v1/auth/logout",
            credential: .sessionBody
        ))
    }

    // MARK: - A07: Refresh Session

    public func refreshSession() async -> ApiResponse<RefreshSessionResult> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/refresh",
            credential: .sessionBody
        ))
    }

    // MARK: - A08: Me

    public func me() async -> ApiResponse<AuthUser> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/auth/me",
            credential: .sessionToken
        ))
    }

    // MARK: - A09: Delete Account

    public func deleteAccount() async -> ApiResponse<MessageResult> {
        await client.request(RequestOptions(
            method: .delete,
            path: "/v1/auth/me",
            credential: .sessionToken
        ))
    }

    // MARK: - A10: Export Data

    public func exportData() async -> ApiResponse<DataExportResult> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/auth/me/export",
            credential: .sessionToken
        ))
    }
}
