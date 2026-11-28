import Foundation
import ScaleMuleCore

// The shared phone account, on the app's own screens.
//
// A person types a phone number, gets a six-digit code by text and is signed
// in. There is no password and no email. The same two calls create the
// account the first time and sign in every time after that, and the account
// works in every ScaleMule app (it is a Ledvery account).
//
//     guard let number = PhoneNumber(typed: typed) else { /* ask again */ }
//     switch await auth.sendLedveryPhoneCode(phone: number.e164) {
//     case .success(let sent): // show the code screen; sent.resendAfterSeconds
//     case .failure(let error): // show error.message
//     }
//     switch await auth.signInWithLedveryPhone(phone: number.e164, code: code) {
//     case .success(let signIn): // signed in; signIn.isNewUser
//     case .failure(let error):  // rawCode == phoneCodeInvalidCode: ask again
//     }
//
// Give the code field `.textContentType(.oneTimeCode)` and iOS offers the
// code from Messages above the keyboard.
//
// The app holds only its public API key. The application must have native
// phone sign-in enabled on the platform; otherwise both calls fail with
// `rawCode == AuthService.nativePhoneNotEnabledCode`.

/// A code was texted.
public struct LedveryPhoneCodeSent: Sendable, Equatable, Decodable {
    /// The number the code went to, as the server stores it.
    public let phone: String
    /// How long to wait before offering "Send a new code".
    public let resendAfterSeconds: Int
    /// How long the code can be used.
    public let expiresInSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case phone
        case resendAfterSeconds = "resend_after_seconds"
        case expiresInSeconds = "expires_in_seconds"
    }

    public init(phone: String, resendAfterSeconds: Int, expiresInSeconds: Int) {
        self.phone = phone
        self.resendAfterSeconds = resendAfterSeconds
        self.expiresInSeconds = expiresInSeconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        phone = try values.decode(String.self, forKey: .phone)
        resendAfterSeconds = try values.decodeIfPresent(Int.self, forKey: .resendAfterSeconds) ?? 30
        expiresInSeconds = try values.decodeIfPresent(Int.self, forKey: .expiresInSeconds) ?? 600
    }
}

/// Signed in with a phone number.
public struct LedveryPhoneSignIn: Sendable, Equatable {
    public let user: AuthUser
    /// True the first time this number is used in this app.
    public let isNewUser: Bool
}

extension AuthService {
    /// The application has not turned on phone sign-in.
    public static let nativePhoneNotEnabledCode = "NATIVE_PHONE_NOT_ENABLED"
    /// The code is wrong or too old.
    public static let phoneCodeInvalidCode = "PHONE_CODE_INVALID"
    /// We cannot text this number (a landline, or a country not served yet).
    public static let phoneNotSupportedCode = "PHONE_NOT_SUPPORTED"

    private static func ledveryPhonePath(_ action: String) -> String {
        "/v1/auth/oauth/\(ledveryProvider)/phone-native/\(action)"
    }

    /// Texts a six-digit code to `phone` (E.164). Call it again to send a
    /// new code. It never says whether the number already has an account.
    /// Asking too often fails with `code == .rateLimited`.
    public func sendLedveryPhoneCode(phone: String) async -> ApiResponse<LedveryPhoneCodeSent> {
        await client.request(RequestOptions(
            method: .post,
            path: Self.ledveryPhonePath("start"),
            body: ["phone": phone.trimmingCharacters(in: .whitespacesAndNewlines)],
            credential: .none,
            retryable: false
        ))
    }

    /// Checks the texted code and signs the person in, creating their account
    /// the first time. The session is stored like any other sign-in.
    public func signInWithLedveryPhone(phone: String, code: String) async -> ApiResponse<LedveryPhoneSignIn> {
        let result: ApiResponse<OAuthCallbackResult> = await client.request(RequestOptions(
            method: .post,
            path: Self.ledveryPhonePath("verify"),
            body: [
                "phone": phone.trimmingCharacters(in: .whitespacesAndNewlines),
                "code": code.filter { !$0.isWhitespace },
            ],
            credential: .none,
            retryable: false
        ))
        switch result {
        case .success(let signIn):
            await app?.setCredentials(signIn.toCredentialSet(), user: signIn.user)
            return .success(LedveryPhoneSignIn(user: signIn.user, isNewUser: signIn.isNewUser))
        case .failure(let error):
            return .failure(error)
        }
    }
}
