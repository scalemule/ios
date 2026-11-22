import Foundation
import ScaleMuleCore

/// First step of authenticator-app setup during sign-in.
public struct TotpSetupStart: Sendable, Decodable, Equatable {
    /// Base32 secret to type into an authenticator app.
    public let secret: String
    /// `otpauth://` URI: open it or show it as a QR code.
    public let qrCodeUri: String
    public let issuer: String
    public let accountName: String

    private enum CodingKeys: String, CodingKey {
        case secret, issuer
        case qrCodeUri = "qr_code_uri"
        case accountName = "account_name"
    }
}

public struct EmailSetupCodeSent: Sendable, Decodable, Equatable {
    public let message: String?
    public let expiresInSeconds: Int?
    public let emailMasked: String?

    private enum CodingKeys: String, CodingKey {
        case message
        case expiresInSeconds = "expires_in_seconds"
        case emailMasked = "email_masked"
    }
}

/// Two-step sign-in is on and the sign-in is complete.
public struct MFASetupCompletion: Sendable, Decodable {
    public let login: LoginResult
    /// "totp" or "email".
    public let mfaMethod: String
    /// One-time backup codes (authenticator setup only). Show them once.
    public let backupCodes: [String]

    private enum CodingKeys: String, CodingKey {
        case mfaMethod = "mfa_method"
        case backupCodes = "backup_codes"
    }

    public init(from decoder: Decoder) throws {
        login = try LoginResult(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mfaMethod = try c.decodeIfPresent(String.self, forKey: .mfaMethod) ?? ""
        backupCodes = try c.decodeIfPresent([String].self, forKey: .backupCodes) ?? []
    }
}

// MARK: - Two-step setup during sign-in

/// When an app requires two-step sign-in and the person has none, `login`
/// fails with `MFA_SETUP_REQUIRED` and the auth state's
/// `MFASetupRequirement.setupToken`. These calls use that token to set up an
/// authenticator app or emailed codes and then finish the same sign-in.
/// An error with `rawCode` `MFA_SETUP_EXPIRED` means the
/// token is used up or expired; send the person back to sign in.
extension AuthService {
    public static let mfaSetupExpiredCode = "MFA_SETUP_EXPIRED"

    public func startTotpSetup(setupToken: String) async -> ApiResponse<TotpSetupStart> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/mfa/setup/totp/start",
            body: ["setup_token": setupToken],
            credential: .none,
            retryable: false
        ))
    }

    /// Confirm the six-digit code from the authenticator app. On success the
    /// person is signed in.
    public func confirmTotpSetup(setupToken: String, code: String) async -> ApiResponse<MFASetupCompletion> {
        await completeSetup(path: "/v1/auth/mfa/setup/totp/confirm", setupToken: setupToken, code: code)
    }

    public func sendEmailSetupCode(setupToken: String) async -> ApiResponse<EmailSetupCodeSent> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/mfa/setup/email/send",
            body: ["setup_token": setupToken],
            credential: .none,
            retryable: false
        ))
    }

    /// Confirm the emailed code. On success the person is signed in.
    public func confirmEmailSetup(setupToken: String, code: String) async -> ApiResponse<MFASetupCompletion> {
        await completeSetup(path: "/v1/auth/mfa/setup/email/confirm", setupToken: setupToken, code: code)
    }

    private func completeSetup(path: String, setupToken: String, code: String) async -> ApiResponse<MFASetupCompletion> {
        let result: ApiResponse<MFASetupCompletion> = await client.request(RequestOptions(
            method: .post,
            path: path,
            body: ["setup_token": setupToken, "code": code.trimmingCharacters(in: .whitespaces)],
            credential: .none,
            retryable: false
        ))
        if case .success(let done) = result {
            await app?.setCredentials(done.login.toCredentialSet(), user: done.login.user)
        }
        return result
    }
}
