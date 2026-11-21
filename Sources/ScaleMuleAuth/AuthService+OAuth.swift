import Foundation
import ScaleMuleCore

extension AuthService {
    // MARK: - A19: Get OAuth URL

    /// Get the authorization URL for an OAuth provider.
    ///
    /// - Parameters:
    ///   - redirectUri: where the provider sends the user back. Native apps pass
    ///     their own callback (for example `myapp://oauth/ledvery/callback`); it
    ///     must be registered with the provider. `nil` uses the app's configured one.
    ///   - upstream: for `ledvery`, which sign-in Ledvery should open (see `LedveryUpstream`).
    ///   - prompt: OIDC `prompt` (`login`, `select_account`, `consent` or `none`).
    public func getOAuthUrl(
        provider: String,
        redirectUri: String? = nil,
        upstream: String? = nil,
        prompt: String? = nil
    ) async -> ApiResponse<OAuthUrl> {
        var query: [String: String] = [:]
        if let redirectUri { query["redirect_uri"] = redirectUri }
        if let upstream { query["upstream"] = upstream }
        if let prompt { query["prompt"] = prompt }
        return await client.request(RequestOptions(
            method: .get,
            path: "/v1/auth/oauth/\(provider)/authorize",
            query: query.isEmpty ? nil : query,
            credential: .none
        ))
    }

    // MARK: - A20: Handle OAuth Callback

    /// Exchange an OAuth authorization code for a session. Returns the result
    /// only; call `app.setCredentials` to sign in, or use `signInWithLedvery`,
    /// which does both.
    public func handleOAuthCallback(
        provider: String,
        code: String,
        state: String? = nil
    ) async -> ApiResponse<OAuthCallbackResult> {
        var query: [String: String] = ["code": code]
        if let state { query["state"] = state }

        return await client.request(RequestOptions(
            method: .get,
            path: "/v1/auth/oauth/\(provider)/callback",
            query: query,
            credential: .none
        ))
    }

    // MARK: - A22: List OAuth Providers

    public func listOAuthProviders() async -> ApiResponse<ListLinkedProvidersResult> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/auth/oauth/providers",
            credential: .sessionToken
        ))
    }

    // MARK: - A23: Unlink OAuth Provider

    public func unlinkOAuthProvider(provider: String) async -> ApiResponse<MessageResult> {
        await client.request(RequestOptions(
            method: .delete,
            path: "/v1/auth/oauth/providers/\(provider)",
            credential: .sessionToken
        ))
    }
}
