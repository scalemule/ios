import Foundation
import ScaleMuleCore

public final class AuthMFASubService: Sendable {
    private let client: HTTPClient

    init(client: HTTPClient) {
        self.client = client
    }

    // MARK: - A33: Get MFA Status

    public func getStatus() async -> ApiResponse<MfaStatus> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/auth/mfa/status",
            credential: .sessionToken
        ))
    }

    // MARK: - A34: Setup TOTP

    public func setupTotp() async -> ApiResponse<TotpSetup> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/mfa/totp/setup",
            credential: .sessionToken
        ))
    }

    // MARK: - A35: Verify TOTP Setup

    public func verifySetup(code: String) async -> ApiResponse<MessageResult> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/mfa/totp/verify-setup",
            body: ["code": code],
            credential: .sessionToken
        ))
    }

    // MARK: - A36: Enable SMS MFA

    public func enableSms() async -> ApiResponse<MessageResult> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/mfa/sms/enable",
            credential: .sessionToken
        ))
    }

    // MARK: - A37: Enable Email MFA

    public func enableEmail() async -> ApiResponse<MessageResult> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/mfa/email/enable",
            credential: .sessionToken
        ))
    }

    // MARK: - A38: Disable MFA

    public func disable(password: String, code: String? = nil) async -> ApiResponse<MessageResult> {
        var body: [String: Any] = ["password": password]
        if let code { body["code"] = code }

        return await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/mfa/disable",
            body: body,
            credential: .sessionToken
        ))
    }

    // MARK: - A39: Regenerate Backup Codes

    public func regenerateBackupCodes() async -> ApiResponse<BackupCodes> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/mfa/backup-codes/regenerate",
            credential: .sessionToken
        ))
    }

    // MARK: - A40: Send MFA Code

    /// Send MFA code during login challenge. Uses pending_token, NOT session auth.
    public func sendCode(pendingToken: String, method: MfaSendChannel) async -> ApiResponse<MfaSendCodeResult> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/mfa/send-code",
            body: ["pending_token": pendingToken, "method": method.rawValue],
            credential: .none
        ))
    }

    // MARK: - A41: Verify MFA

    /// Verify MFA during login challenge. Uses pending_token, NOT session auth.
    public func verify(pendingToken: String, code: String, method: String? = nil) async -> ApiResponse<MfaVerifyResult> {
        var body: [String: Any] = ["pending_token": pendingToken, "code": code]
        if let method { body["method"] = method }

        return await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/mfa/verify",
            body: body,
            credential: .none
        ))
    }
}
