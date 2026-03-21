import Foundation
import ScaleMuleCore

public final class AuthService: @unchecked Sendable {
    public let client: HTTPClient
    let app: ScaleMuleApp?
    public let sessions: AuthSessionsSubService
    public let devices: AuthDevicesSubService
    public let loginHistory: AuthLoginHistorySubService
    public let mfa: AuthMFASubService

    /// Create with full app integration — login/logout drive auth state transitions.
    public init(app: ScaleMuleApp) {
        self.app = app
        self.client = app.client
        self.sessions = AuthSessionsSubService(client: app.client)
        self.devices = AuthDevicesSubService(client: app.client)
        self.loginHistory = AuthLoginHistorySubService(client: app.client)
        self.mfa = AuthMFASubService(client: app.client, app: app)
    }

    /// Create with client only — no automatic state transitions.
    public init(client: HTTPClient) {
        self.app = nil
        self.client = client
        self.sessions = AuthSessionsSubService(client: client)
        self.devices = AuthDevicesSubService(client: client)
        self.loginHistory = AuthLoginHistorySubService(client: client)
        self.mfa = AuthMFASubService(client: client)
    }

    // MARK: - A02: Register

    /// Register returns User only — NO session. Transitions to .pendingEmailVerification.
    public func register(
        email: String,
        password: String,
        name: String? = nil,
        username: String? = nil,
        phone: String? = nil,
        tosAccepted: Bool? = nil,
        tosVersion: String? = nil,
        privacyPolicyVersion: String? = nil
    ) async -> ApiResponse<RegisterResult> {
        var body: [String: Any] = [
            "email": email,
            "password": password,
        ]
        if let name { body["full_name"] = name }
        if let username { body["username"] = username }
        if let phone { body["phone"] = phone }
        if let tosAccepted { body["tos_accepted"] = tosAccepted }
        if let tosVersion { body["tos_version"] = tosVersion }
        if let privacyPolicyVersion { body["privacy_policy_version"] = privacyPolicyVersion }

        let result: ApiResponse<RegisterResult> = await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/register",
            body: body,
            credential: .none
        ))

        if case .success(let user) = result {
            await app?.authState.transition(to: .pendingEmailVerification(user))
        }
        return result
    }

    // MARK: - A05: Login

    /// Login. On success, persists credentials and transitions to .authenticated.
    /// On MFA challenge (202), transitions to .mfaRequired.
    public func login(
        email: String,
        password: String,
        rememberMe: Bool? = nil,
        deviceFingerprint: String? = nil
    ) async -> ApiResponse<LoginResult> {
        await app?.authState.transition(to: .loading)

        var body: [String: Any] = [
            "email": email,
            "password": password,
        ]
        if let rememberMe { body["remember_me"] = rememberMe }
        if let deviceFingerprint { body["device_fingerprint"] = deviceFingerprint }

        let result: ApiResponse<LoginResult> = await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/login",
            body: body,
            credential: .none
        ))

        switch result {
        case .success(let login):
            let creds = login.toCredentialSet()
            await app?.setCredentials(creds, user: login.user)
        case .failure(let error):
            if error.code == .mfaRequired, let details = error.details {
                let challenge = MFAChallenge(
                    pendingToken: (details["pending_token"]?.value as? String) ?? "",
                    mfaMethod: (details["mfa_method"]?.value as? String) ?? "",
                    expiresIn: (details["expires_in"]?.value as? Int) ?? 600,
                    allowedMethods: (details["allowed_methods"]?.value as? [String]) ?? []
                )
                await app?.authState.transition(to: .mfaRequired(challenge))
            } else if error.code == .mfaSetupRequired {
                let req = MFASetupRequirement(
                    message: error.message,
                    requirementSource: (error.details?["requirement_source"]?.value as? String) ?? "unknown"
                )
                await app?.authState.transition(to: .mfaSetupRequired(req))
            } else {
                await app?.authState.transition(to: .error(error))
            }
        }
        return result
    }

    // MARK: - A06: Logout

    /// Logout. On success, clears credentials and transitions to .unauthenticated.
    public func logout() async -> ApiResponse<EmptyResponse> {
        let result = await client.requestVoid(RequestOptions(
            method: .post,
            path: "/v1/auth/logout",
            credential: .sessionBody
        ))
        // Clear session regardless of whether the server call succeeded
        await app?.clearSession()
        return result
    }

    // MARK: - A07: Refresh Session

    public func refreshSession() async -> ApiResponse<RefreshSessionResult> {
        let result: ApiResponse<RefreshSessionResult> = await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/refresh",
            credential: .sessionBody
        ))
        if case .success(let refresh) = result {
            let expiry = DateFormatting.parseISO8601(refresh.expiresAt) ?? Date().addingTimeInterval(3600)
            try? await app?.sessionManager.refreshSession(refresh.sessionToken, expiresAt: expiry)
        }
        return result
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
        let result: ApiResponse<MessageResult> = await client.request(RequestOptions(
            method: .delete,
            path: "/v1/auth/me",
            credential: .sessionToken
        ))
        if case .success = result {
            await app?.clearSession()
        }
        return result
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
