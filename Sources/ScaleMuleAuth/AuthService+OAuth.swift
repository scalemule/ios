import Foundation
import ScaleMuleCore

extension AuthService {
    // MARK: - A19: Get OAuth URL

    /// Get the authorization URL for an OAuth provider.
    /// NOTE: Backend builds URL with server-side config — does not accept client-side redirectUri.
    /// Native app redirect support (custom scheme / universal links) requires backend work.
    public func getOAuthUrl(provider: String) async -> ApiResponse<OAuthUrl> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/auth/oauth/\(provider)/authorize",
            credential: .none
        ))
    }

    // MARK: - A20: Handle OAuth Callback

    /// Exchange an OAuth authorization code for a session.
    /// Blocked on backend native redirect support (A19).
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
