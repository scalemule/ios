import CryptoKit
import Foundation
import ScaleMuleCore
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

// Sign in with Apple, through Ledvery: the iPhone shows Apple's own sheet
// and hands back an Apple identity token; Ledvery checks it with Apple and
// the auth service turns it into a ScaleMule session, exactly as for
// "Continue with Google" (same account linking, same outcomes). The app
// holds only its public API key, and needs the "Sign in with Apple"
// capability.
//
// Use Apple's `SignInWithAppleButton` (App Review expects Apple's button):
//
//     let nonce = AppleSignInNonce()
//     SignInWithAppleButton(.continue) { request in
//         request.requestedScopes = [.fullName, .email]
//         request.nonce = nonce.hashed
//     } onCompletion: { result in
//         Task { await auth.completeAppleSignIn(result, nonce: nonce) }
//     }
//
// or `signInWithApple()` with a button of your own.

/// A one-time value tying Apple's answer to this sign-in (so a token taken
/// from elsewhere cannot be replayed). Make a new one for every attempt.
public struct AppleSignInNonce: Sendable, Equatable {
    /// Sent to the auth service.
    public let raw: String
    /// Given to Apple (`request.nonce`): SHA-256 of `raw`, hex.
    public let hashed: String

    public init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        self.init(raw: Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: ""))
    }

    init(raw: String) {
        self.raw = raw
        hashed = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension AuthService {
    /// Send what Apple returned to ScaleMule (through Ledvery) and sign in.
    /// On success the session is stored and auth state becomes `.authenticated`.
    public func completeAppleSignIn(
        identityToken: String,
        nonce: AppleSignInNonce,
        authorizationCode: String? = nil,
        givenName: String? = nil,
        familyName: String? = nil
    ) async -> ApiResponse<LedverySignInOutcome> {
        var body: [String: Any] = ["identity_token": identityToken, "raw_nonce": nonce.raw]
        if let authorizationCode, !authorizationCode.isEmpty { body["authorization_code"] = authorizationCode }
        if let givenName = givenName?.trimmingCharacters(in: .whitespacesAndNewlines), !givenName.isEmpty { body["given_name"] = givenName }
        if let familyName = familyName?.trimmingCharacters(in: .whitespacesAndNewlines), !familyName.isEmpty { body["family_name"] = familyName }
        let result: ApiResponse<OAuthCallbackResult> = await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/oauth/\(Self.ledveryProvider)/apple-native",
            body: body,
            credential: .none,
            retryable: false
        ))
        switch result {
        case .success(let signIn):
            await app?.setCredentials(signIn.toCredentialSet(), user: signIn.user)
            return .success(.signedIn(signIn.user, isNewUser: signIn.isNewUser))
        case .failure(let error):
            if error.rawCode == Self.linkRequiredCode, let challenge = Self.linkChallenge(from: error) {
                return .success(.linkRequired(challenge))
            }
            return .failure(error)
        }
    }

    #if canImport(AuthenticationServices)
    /// Finish from `SignInWithAppleButton`'s `onCompletion`. A closed sheet
    /// fails with `rawCode == AuthService.signInCancelledCode`.
    public func completeAppleSignIn(_ result: Result<ASAuthorization, Error>, nonce: AppleSignInNonce) async -> ApiResponse<LedverySignInOutcome> {
        switch result {
        case .failure(let error):
            return .failure(Self.appleSheetError(error))
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                return .failure(ApiError(code: .unknown, message: "Apple did not return a sign-in token. Try again."))
            }
            return await completeAppleSignIn(
                identityToken: token,
                nonce: nonce,
                authorizationCode: credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) },
                givenName: credential.fullName?.givenName,
                familyName: credential.fullName?.familyName
            )
        }
    }

    /// Show Apple's sheet and sign in (for an app's own button; Apple's
    /// `SignInWithAppleButton` with `completeAppleSignIn(_:nonce:)` is preferred).
    @MainActor
    public func signInWithApple(presentationAnchor: ASPresentationAnchor? = nil) async -> ApiResponse<LedverySignInOutcome> {
        let nonce = AppleSignInNonce()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = nonce.hashed
        let result = await AppleSheet.run(request, anchor: presentationAnchor)
        return await completeAppleSignIn(result, nonce: nonce)
    }

    static func appleSheetError(_ error: Error) -> ApiError {
        if let apple = error as? ASAuthorizationError, apple.code == .canceled {
            return ApiError(code: .unauthorized, message: "Sign-in was cancelled.", rawCode: signInCancelledCode)
        }
        return ApiError(code: .unknown, message: "Sign in with Apple didn't finish. Try again.")
    }
    #endif
}

#if canImport(AuthenticationServices)
@MainActor
private final class AppleSheet: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let anchor: ASPresentationAnchor?
    private var continuation: CheckedContinuation<Result<ASAuthorization, Error>, Never>?
    private var controller: ASAuthorizationController?

    private init(anchor: ASPresentationAnchor?) {
        self.anchor = anchor
    }

    static func run(_ request: ASAuthorizationAppleIDRequest, anchor: ASPresentationAnchor?) async -> Result<ASAuthorization, Error> {
        let sheet = AppleSheet(anchor: anchor)
        return await withCheckedContinuation { continuation in
            sheet.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = sheet
            controller.presentationContextProvider = sheet
            sheet.controller = controller
            controller.performRequests()
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated { finish(.success(authorization)) }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        MainActor.assumeIsolated { finish(.failure(error)) }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor ?? Self.defaultAnchor() }
    }

    private func finish(_ result: Result<ASAuthorization, Error>) {
        continuation?.resume(returning: result)
        continuation = nil
        controller = nil
    }

    private static func defaultAnchor() -> ASPresentationAnchor {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        #else
        return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #endif
    }
}
#endif
