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
    /// Authenticated but app-defined post-auth setup not yet complete
    case pendingOnboarding(AuthUser)
    /// No session / logged out / session expired
    case unauthenticated
    /// Auth operation failed
    case error(ApiError)
}

public struct AuthUser: Sendable, Equatable, Codable {
    public let id: String
    public let smApplicationId: String?
    public let email: String?
    public let phone: String?
    public let username: String?
    public let fullName: String?
    public let avatarUrl: String?
    public let emailVerified: Bool?
    public let phoneVerified: Bool?
    public let mfaEnabled: Bool?
    public let status: String?
    public let createdAt: String?
    public let updatedAt: String?

    public init(id: String, smApplicationId: String? = nil, email: String? = nil, phone: String? = nil, username: String? = nil, fullName: String? = nil, avatarUrl: String? = nil, emailVerified: Bool? = nil, phoneVerified: Bool? = nil, mfaEnabled: Bool? = nil, status: String? = nil, createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id
        self.smApplicationId = smApplicationId
        self.email = email
        self.phone = phone
        self.username = username
        self.fullName = fullName
        self.avatarUrl = avatarUrl
        self.emailVerified = emailVerified
        self.phoneVerified = phoneVerified
        self.mfaEnabled = mfaEnabled
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case smApplicationId = "sm_application_id"
        case email
        case phone
        case username
        case fullName = "full_name"
        case avatarUrl = "avatar_url"
        case emailVerified = "email_verified"
        case phoneVerified = "phone_verified"
        case mfaEnabled = "mfa_enabled"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct MFAChallenge: Sendable, Equatable, Codable {
    public let pendingToken: String
    public let mfaMethod: String
    public let expiresIn: Int
    public let allowedMethods: [String]

    public init(pendingToken: String, mfaMethod: String, expiresIn: Int, allowedMethods: [String]) {
        self.pendingToken = pendingToken
        self.mfaMethod = mfaMethod
        self.expiresIn = expiresIn
        self.allowedMethods = allowedMethods
    }

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

    public init(message: String, requirementSource: String) {
        self.message = message
        self.requirementSource = requirementSource
    }

    private enum CodingKeys: String, CodingKey {
        case message
        case requirementSource = "requirement_source"
    }
}
