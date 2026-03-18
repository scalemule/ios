import Foundation

public enum AuthState: Sendable, Equatable {
    /// Not yet checked Keychain
    case unknown
    /// Login/register/refresh in progress
    case loading
    /// Valid session
    case authenticated(AuthUser)
    /// Registered but email not verified — no session
    case pendingEmailVerification(AuthUser)
    /// Login returned 202 — user must complete MFA
    case mfaRequired(MFAChallenge)
    /// Login returned 403 — user must set up MFA (policy)
    case mfaSetupRequired(MFASetupRequirement)
    /// No session / logged out / session expired
    case unauthenticated
    /// Auth operation failed
    case error(ApiError)
}

public struct AuthUser: Sendable, Equatable, Codable {
    public let id: String
    public let email: String?
    public let phone: String?
    public let username: String?
    public let fullName: String?
    public let avatarUrl: String?
    public let emailVerified: Bool?
    public let phoneVerified: Bool?
    public let mfaEnabled: Bool?
    public let createdAt: String?
    public let updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case email
        case phone
        case username
        case fullName = "full_name"
        case avatarUrl = "avatar_url"
        case emailVerified = "email_verified"
        case phoneVerified = "phone_verified"
        case mfaEnabled = "mfa_enabled"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct MFAChallenge: Sendable, Equatable, Codable {
    public let pendingToken: String
    public let mfaMethod: String
    public let expiresIn: Int
    public let allowedMethods: [String]

    private enum CodingKeys: String, CodingKey {
        case pendingToken = "pending_token"
        case mfaMethod = "mfa_method"
        case expiresIn = "expires_in"
        case allowedMethods = "allowed_methods"
    }
}

public struct MFASetupRequirement: Sendable, Equatable, Codable {
    public let message: String
    public let requirementSource: String

    private enum CodingKeys: String, CodingKey {
        case message
        case requirementSource = "requirement_source"
    }
}
