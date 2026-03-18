import Foundation
import ScaleMuleCore

extension AuthService {
    // MARK: - A42: Refresh Access Token

    /// Refresh the access token using a refresh token. Credential: .none (tokens.rs:182).
    /// Only available when refresh tokens are enabled for the app.
    public func refreshAccessToken(refreshToken: String) async -> ApiResponse<RefreshAccessTokenResult> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/token/refresh",
            body: ["refresh_token": refreshToken],
            credential: .none
        ))
    }

    // MARK: - A43: Revoke Refresh Token

    /// Revoke a refresh token. Credential: .sessionToken (tokens.rs:276).
    public func revokeRefreshToken(refreshToken: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .post,
            path: "/v1/auth/token/revoke",
            body: ["refresh_token": refreshToken],
            credential: .sessionToken
        ))
    }
}
