import Foundation

public enum CredentialStrategy: Sendable {
    /// Authorization: Bearer {accessToken ?? sessionToken}
    case accessToken
    /// Authorization: Bearer {sessionToken} (always, ignores accessToken)
    case sessionToken
    /// Sends session_token in JSON body (for logout, refresh)
    case sessionBody
    /// No auth (register, login, forgot-password, etc.)
    case none
}
