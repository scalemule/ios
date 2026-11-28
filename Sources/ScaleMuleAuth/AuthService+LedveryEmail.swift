import Foundation
import ScaleMuleCore

// The shared email account, on the app's own screens.
//
// "Create Account" and "Sign In" in an app can use the email account that
// works in every ScaleMule app (a Ledvery account) without opening a web
// page. The person types their email and password in the app; the auth
// service and Ledvery do the rest, and sign-in finishes exactly as
// "Continue with Google" does (same account linking, same outcomes).
//
//     // Create Account
//     let created = await auth.registerLedveryEmailAccount(email: email, password: password, name: name)
//     // -> show a screen for the six-digit code that was emailed
//     _ = await auth.confirmLedveryEmail(email: email, code: code)
//     _ = await auth.signInWithLedveryEmail(email: email, password: password)
//
//     // Sign In
//     switch await auth.signInWithLedveryEmail(email: email, password: password) {
//     case .success(.signedIn): ...
//     case .success(.emailConfirmationRequired): // show the code screen
//     case .success(.mfaCodeRequired):           // ask for the code, call again with mfaCode
//     case .success(.linkRequired(let challenge)): // linkLedveryAccount(...)
//     case .failure(let error):                  // show error.message
//     }
//
// The app holds only its public API key. The application must have native
// email sign-in enabled on the platform; otherwise every call fails with
// `rawCode == AuthService.nativeEmailNotEnabledCode`.

/// What creating a shared email account answered. No session is opened:
/// the person confirms their address first.
public struct LedveryEmailRegistration: Sendable, Equatable, Decodable {
    /// The address as stored, to show on the code screen.
    public let email: String
    public let verificationRequired: Bool
    /// `otp_code` (a six-digit code to type) or `magic_link` (a link to tap).
    public let verificationMethod: String

    private enum CodingKeys: String, CodingKey {
        case email
        case verificationRequired = "verification_required"
        case verificationMethod = "verification_method"
    }
}

public enum LedveryEmailSignInOutcome: Sendable, Equatable {
    /// Signed in. The SDK stored the session and moved auth state to `.authenticated`.
    case signedIn(AuthUser, isNewUser: Bool)
    /// The password was right but the address is not confirmed yet: show the
    /// code screen (`confirmLedveryEmail`, `resendLedveryEmailCode`), then sign in again.
    case emailConfirmationRequired(message: String)
    /// The account uses two-step sign-in: call again with `mfaCode`.
    case mfaCodeRequired(message: String)
    /// This app already has an account with that email from before: ask for
    /// that account's password, then call `linkLedveryAccount`.
    case linkRequired(LedveryLinkChallenge)
}

extension AuthService {
    public static let nativeEmailNotEnabledCode = "NATIVE_EMAIL_NOT_ENABLED"
    /// Wrong email or password. The message never says which.
    public static let invalidCredentialsCode = "INVALID_CREDENTIALS"
    /// The emailed code is wrong or has expired.
    public static let verificationCodeInvalidCode = "VERIFICATION_CODE_INVALID"

    private static func ledveryEmailPath(_ action: String) -> String {
        "/v1/auth/oauth/\(ledveryProvider)/email-native/\(action)"
    }

    /// Create a shared email account. A six-digit code is emailed; nobody is
    /// signed in until the address is confirmed.
    public func registerLedveryEmailAccount(
        email: String,
        password: String,
        name: String? = nil
    ) async -> ApiResponse<LedveryEmailRegistration> {
        var body: [String: Any] = [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password,
        ]
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            body["full_name"] = name
        }
        return await client.request(RequestOptions(
            method: .post,
            path: Self.ledveryEmailPath("register"),
            body: body,
            credential: .none,
            retryable: false
        ))
    }

    /// Confirm the address with the emailed code. Succeeds again if the
    /// address is already confirmed.
    public func confirmLedveryEmail(email: String, code: String) async -> ApiResponse<Bool> {
        let result: ApiResponse<LedveryEmailVerified> = await client.request(RequestOptions(
            method: .post,
            path: Self.ledveryEmailPath("verify"),
            body: [
                "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
                "code": code.filter { !$0.isWhitespace },
            ],
            credential: .none,
            retryable: false
        ))
        switch result {
        case .success(let verified): return .success(verified.verified)
        case .failure(let error): return .failure(error)
        }
    }

    /// Email a new code.
    public func resendLedveryEmailCode(email: String) async -> ApiResponse<MessageResult> {
        await client.request(RequestOptions(
            method: .post,
            path: Self.ledveryEmailPath("resend"),
            body: ["email": email.trimmingCharacters(in: .whitespacesAndNewlines)],
            credential: .none,
            retryable: false
        ))
    }

    /// Email a link to choose a new password. The answer is the same whether
    /// or not the address has an account.
    public func sendLedveryPasswordReset(email: String) async -> ApiResponse<MessageResult> {
        await client.request(RequestOptions(
            method: .post,
            path: Self.ledveryEmailPath("forgot"),
            body: ["email": email.trimmingCharacters(in: .whitespacesAndNewlines)],
            credential: .none,
            retryable: false
        ))
    }

    /// Sign in with the shared email account. On `.signedIn` the session is
    /// stored and auth state becomes `.authenticated`.
    public func signInWithLedveryEmail(
        email: String,
        password: String,
        mfaCode: String? = nil
    ) async -> ApiResponse<LedveryEmailSignInOutcome> {
        var body: [String: Any] = [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password,
        ]
        if let mfaCode = mfaCode?.trimmingCharacters(in: .whitespacesAndNewlines), !mfaCode.isEmpty {
            body["mfa_code"] = mfaCode
        }
        let result: ApiResponse<OAuthCallbackResult> = await client.request(RequestOptions(
            method: .post,
            path: Self.ledveryEmailPath("login"),
            body: body,
            credential: .none,
            retryable: false
        ))
        switch result {
        case .success(let signIn):
            await app?.setCredentials(signIn.toCredentialSet(), user: signIn.user)
            return .success(.signedIn(signIn.user, isNewUser: signIn.isNewUser))
        case .failure(let error):
            switch error.rawCode {
            case "EMAIL_NOT_VERIFIED":
                return .success(.emailConfirmationRequired(message: error.message))
            case "MFA_CODE_REQUIRED":
                return .success(.mfaCodeRequired(message: error.message))
            case Self.linkRequiredCode:
                if let challenge = Self.linkChallenge(from: error) {
                    return .success(.linkRequired(challenge))
                }
                return .failure(error)
            default:
                return .failure(error)
            }
        }
    }
}

private struct LedveryEmailVerified: Decodable {
    let verified: Bool
}
