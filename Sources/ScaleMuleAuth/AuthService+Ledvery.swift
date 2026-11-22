import Foundation
import ScaleMuleCore
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

// Ledvery is ScaleMule's shared account service. An app signs people in through
// Ledvery so one account (and one Google sign-in) works in every ScaleMule app.
//
// The flow: the auth service builds the Ledvery address (it keeps the app's
// Ledvery secret and the PKCE verifier on the server), the app opens it in a
// system sign-in sheet, Ledvery returns to the app's callback with a one-time
// code, and the auth service turns that code into a ScaleMule session.
// The app itself only ever holds its public API key.

/// Which sign-in Ledvery opens.
public enum LedveryUpstream: String, Sendable, CaseIterable {
    case google
    /// Email and password through the ScaleMule consumer account.
    case email = "scalemule_consumer"
}

/// The Ledvery address to open, from `startLedverySignIn`.
public struct LedveryAuthorization: Sendable, Equatable {
    public let url: URL
    public let state: String?
}

/// The person's email already belongs to an account in this app. They must
/// prove they own it (`linkLedveryAccount`) before the sign-in is attached.
public struct LedveryLinkChallenge: Sendable, Equatable {
    public let challengeId: String
    /// Masked email of the existing account, for example `p***@example.com`.
    public let emailHint: String
    public let expiresAt: String?
    /// Proofs the server accepts, for example `["password"]`.
    public let methods: [String]

    public init(challengeId: String, emailHint: String, expiresAt: String? = nil, methods: [String] = ["password"]) {
        self.challengeId = challengeId
        self.emailHint = emailHint
        self.expiresAt = expiresAt
        self.methods = methods
    }
}

/// The existing account's email is not confirmed yet, so the server emailed a
/// code. Call `linkLedveryAccount` again with the same password plus this token
/// and the code the person received.
public struct LedveryEmailCodeChallenge: Sendable, Equatable {
    public let challengeToken: String
    public let expiresIn: Int
    public let message: String
}

public enum LedverySignInOutcome: Sendable, Equatable {
    /// Signed in. The SDK stored the session and moved auth state to `.authenticated`.
    case signedIn(AuthUser, isNewUser: Bool)
    /// Ask for the existing account's password, then call `linkLedveryAccount`.
    case linkRequired(LedveryLinkChallenge)
}

public enum LedveryLinkOutcome: Sendable, Equatable {
    /// Linked and signed in. The SDK stored the session.
    case signedIn(AuthUser)
    /// The account uses two-step sign-in: call again with `mfaCode`.
    case mfaCodeRequired(message: String)
    /// Call again with the emailed code (see `LedveryEmailCodeChallenge`).
    case emailCodeRequired(LedveryEmailCodeChallenge)
}

extension AuthService {
    /// Provider name of Ledvery in the auth service.
    public static let ledveryProvider = "ledvery"
    /// `rawCode` of the error returned when the person closes the sign-in sheet.
    public static let signInCancelledCode = "SIGN_IN_CANCELLED"
    /// `rawCode` of the 409 answer when the email already has an account.
    public static let linkRequiredCode = "LINK_REQUIRED"

    // MARK: - Step 1: where to send the person

    /// Ask the auth service for the Ledvery address to open.
    ///
    /// - Parameters:
    ///   - redirectUri: the app's callback, exactly as registered for the app's
    ///     Ledvery client (for example `firehosy://oauth/ledvery/callback`).
    ///   - upstream: open Google or email sign-in directly. `nil` lets Ledvery
    ///     reuse an existing Ledvery session or use the app's default.
    ///   - prompt: `select_account` to always offer a different account.
    public func startLedverySignIn(
        redirectUri: String,
        upstream: LedveryUpstream? = nil,
        prompt: String? = nil
    ) async -> ApiResponse<LedveryAuthorization> {
        let result = await getOAuthUrl(
            provider: Self.ledveryProvider,
            redirectUri: redirectUri,
            upstream: upstream?.rawValue,
            prompt: prompt
        )
        switch result {
        case .success(let oauthUrl):
            guard let url = URL(string: oauthUrl.url) else {
                return .failure(ApiError(code: .internalError, message: "The sign-in address is not valid"))
            }
            return .success(LedveryAuthorization(url: url, state: oauthUrl.state))
        case .failure(let error):
            return .failure(error)
        }
    }

    // MARK: - Step 2: finish with the callback Ledvery returned

    /// Finish a Ledvery sign-in from the callback URL the sign-in sheet returned.
    /// On success the session is stored and auth state becomes `.authenticated`.
    public func completeLedverySignIn(callbackURL: URL) async -> ApiResponse<LedverySignInOutcome> {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value.flatMap { $0.isEmpty ? nil : $0 }
        }

        if let refused = value("error") {
            let cancelled = refused == "access_denied"
            return .failure(ApiError(
                code: cancelled ? .unauthorized : .unknown,
                message: value("error_description")
                    ?? (cancelled ? "Sign-in was cancelled." : "Sign-in could not be completed."),
                rawCode: cancelled ? Self.signInCancelledCode : refused
            ))
        }
        guard let code = value("code") else {
            return .failure(ApiError(
                code: .validationError,
                message: "The sign-in did not return a code."
            ))
        }

        let result = await handleOAuthCallback(
            provider: Self.ledveryProvider,
            code: code,
            state: value("state")
        )
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

    // MARK: - Step 3 (only when the email already has an account)

    /// Prove ownership of the existing account and attach the Ledvery sign-in to it.
    /// On success the session is stored and auth state becomes `.authenticated`.
    public func linkLedveryAccount(
        challengeId: String,
        password: String,
        mfaCode: String? = nil,
        emailChallengeToken: String? = nil,
        emailCode: String? = nil
    ) async -> ApiResponse<LedveryLinkOutcome> {
        var body: [String: Any] = [
            "challenge_id": challengeId,
            "password": password,
        ]
        if let mfaCode { body["mfa_code"] = mfaCode }
        if let emailChallengeToken { body["challenge_token"] = emailChallengeToken }
        if let emailCode { body["challenge_code"] = emailCode }

        let result: ApiResponse<OAuthCallbackResult> = await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/oauth/\(Self.ledveryProvider)/link",
            body: body,
            credential: .none
        ))
        switch result {
        case .success(let signIn):
            await app?.setCredentials(signIn.toCredentialSet(), user: signIn.user)
            return .success(.signedIn(signIn.user))
        case .failure(let error):
            switch error.rawCode {
            case "MFA_REQUIRED":
                return .success(.mfaCodeRequired(message: error.message))
            case "LOGIN_CHALLENGE_REQUIRED":
                if let challenge = Self.emailCodeChallenge(from: error.message) {
                    return .success(.emailCodeRequired(challenge))
                }
                return .failure(error)
            default:
                return .failure(error)
            }
        }
    }

    // MARK: - Parsing helpers

    static func linkChallenge(from error: ApiError) -> LedveryLinkChallenge? {
        guard let details = error.details,
              let challengeId = details["challenge_id"]?.value as? String,
              !challengeId.isEmpty else {
            return nil
        }
        return LedveryLinkChallenge(
            challengeId: challengeId,
            emailHint: (details["email_hint"]?.value as? String) ?? "",
            expiresAt: details["expires_at"]?.value as? String,
            methods: (details["methods"]?.value as? [Any])?.compactMap { $0 as? String } ?? ["password"]
        )
    }

    /// The auth service sends the email-code challenge as JSON inside `message`.
    static func emailCodeChallenge(from message: String) -> LedveryEmailCodeChallenge? {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["challenge_token"] as? String, !token.isEmpty else {
            return nil
        }
        return LedveryEmailCodeChallenge(
            challengeToken: token,
            expiresIn: (json["expires_in"] as? Int) ?? 600,
            message: (json["message"] as? String) ?? "Enter the code sent to your email."
        )
    }
}

#if canImport(AuthenticationServices) && (os(iOS) || os(macOS))
extension AuthService {
    /// Sign in through Ledvery in the system sign-in sheet, start to finish.
    ///
    /// The sheet shares Safari's cookies (unless `prefersEphemeralWebBrowserSession`),
    /// so someone already signed in to Ledvery on another ScaleMule site continues
    /// in one tap.
    ///
    /// - Parameters:
    ///   - upstream: `.google` opens Google directly; `nil` lets Ledvery decide.
    ///   - callbackURL: the app's callback, registered for its Ledvery client.
    ///     A custom scheme (`myapp://…`) works everywhere; an `https` callback
    ///     needs iOS 17.4 / macOS 14.4 and an associated domain.
    /// - Returns: `.signedIn` or `.linkRequired`. A closed sheet fails with
    ///   `rawCode == AuthService.signInCancelledCode`.
    @MainActor
    public func signInWithLedvery(
        upstream: LedveryUpstream? = .google,
        callbackURL: URL,
        prompt: String? = nil,
        prefersEphemeralWebBrowserSession: Bool = false,
        presentationAnchor: ASPresentationAnchor? = nil
    ) async -> ApiResponse<LedverySignInOutcome> {
        let start = await startLedverySignIn(
            redirectUri: callbackURL.absoluteString,
            upstream: upstream,
            prompt: prompt
        )
        let authorization: LedveryAuthorization
        switch start {
        case .success(let value): authorization = value
        case .failure(let error): return .failure(error)
        }

        let returned: URL
        switch await LedveryWebSession.run(
            url: authorization.url,
            callbackURL: callbackURL,
            prefersEphemeral: prefersEphemeralWebBrowserSession,
            anchor: presentationAnchor
        ) {
        case .success(let url): returned = url
        case .failure(let error): return .failure(error)
        }

        return await completeLedverySignIn(callbackURL: returned)
    }
}

@MainActor
private final class LedveryWebSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor?
    /// Held until the sheet finishes; released in the completion handler.
    private var session: ASWebAuthenticationSession?

    private init(anchor: ASPresentationAnchor?) {
        self.anchor = anchor
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor ?? Self.defaultAnchor() }
    }

    private static func defaultAnchor() -> ASPresentationAnchor {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        if let key = windows.first(where: \.isKeyWindow) ?? windows.first {
            return key
        }
        if let scene = scenes.first {
            return UIWindow(windowScene: scene)
        }
        return ASPresentationAnchor()
        #else
        return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #endif
    }

    static func run(
        url: URL,
        callbackURL: URL,
        prefersEphemeral: Bool,
        anchor: ASPresentationAnchor?
    ) async -> Result<URL, ApiError> {
        let provider = LedveryWebSession(anchor: anchor)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result<URL, ApiError>, Never>) in
            let completion: ASWebAuthenticationSession.CompletionHandler = { returnedURL, error in
                // Capturing `provider` keeps it (and the session it holds) alive
                // until the sheet finishes.
                Task { @MainActor in provider.session = nil }
                if let returnedURL {
                    continuation.resume(returning: .success(returnedURL))
                    return
                }
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(returning: .failure(ApiError(
                        code: .unauthorized,
                        message: "Sign-in was cancelled.",
                        rawCode: AuthService.signInCancelledCode
                    )))
                    return
                }
                continuation.resume(returning: .failure(ApiError(
                    code: .unknown,
                    message: error?.localizedDescription ?? "Sign-in could not be completed."
                )))
            }

            let session: ASWebAuthenticationSession
            if callbackURL.scheme?.lowercased() == "https",
               let host = callbackURL.host,
               #available(iOS 17.4, macOS 14.4, *) {
                session = ASWebAuthenticationSession(
                    url: url,
                    callback: .https(host: host, path: callbackURL.path),
                    completionHandler: completion
                )
            } else {
                session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackURL.scheme,
                    completionHandler: completion
                )
            }
            session.presentationContextProvider = provider
            session.prefersEphemeralWebBrowserSession = prefersEphemeral
            provider.session = session
            if !session.start() {
                provider.session = nil
                continuation.resume(returning: .failure(ApiError(
                    code: .unknown,
                    message: "The sign-in sheet could not be opened."
                )))
            }
        }
    }
}
#endif
