import Foundation

public struct CredentialSet: Sendable, Equatable {
    /// Always present after login. Required in body for logout/refresh.
    public let sessionToken: String
    /// Optional JWT. Only present when refresh tokens are enabled for the app.
    public let accessToken: String?
    /// Optional. Only present when refresh tokens are enabled for the app.
    public let refreshToken: String?
    /// When session expires if idle (sliding window).
    public let sessionExpiresAt: Date
    /// When session expires regardless of activity (hard limit).
    /// Optional: only LoginResponse includes this. RefreshSessionResult, OAuthCallbackResult do not.
    public let absoluteExpiresAt: Date?
    /// When access token expires (nil if no access token).
    public let accessTokenExpiresAt: Date?

    /// Auth mode: .sessionOnly (no JWTs) or .refreshToken (has JWTs).
    public var authMode: AuthMode {
        refreshToken != nil ? .refreshToken : .sessionOnly
    }

    public init(
        sessionToken: String,
        accessToken: String? = nil,
        refreshToken: String? = nil,
        sessionExpiresAt: Date,
        absoluteExpiresAt: Date? = nil,
        accessTokenExpiresAt: Date? = nil
    ) {
        self.sessionToken = sessionToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.sessionExpiresAt = sessionExpiresAt
        self.absoluteExpiresAt = absoluteExpiresAt
        self.accessTokenExpiresAt = accessTokenExpiresAt
    }

    /// Create a new CredentialSet with an updated access token.
    public func withUpdatedAccessToken(_ newAccessToken: String, expiresAt: Date) -> CredentialSet {
        CredentialSet(
            sessionToken: sessionToken,
            accessToken: newAccessToken,
            refreshToken: refreshToken,
            sessionExpiresAt: sessionExpiresAt,
            absoluteExpiresAt: absoluteExpiresAt,
            accessTokenExpiresAt: expiresAt
        )
    }

    /// Create a new CredentialSet with updated session token and expiry.
    public func withRefreshedSession(_ newSessionToken: String, expiresAt: Date) -> CredentialSet {
        CredentialSet(
            sessionToken: newSessionToken,
            accessToken: accessToken,
            refreshToken: refreshToken,
            sessionExpiresAt: expiresAt,
            absoluteExpiresAt: absoluteExpiresAt,
            accessTokenExpiresAt: accessTokenExpiresAt
        )
    }
}

public enum AuthMode: String, Sendable, Equatable {
    case sessionOnly
    case refreshToken
}
