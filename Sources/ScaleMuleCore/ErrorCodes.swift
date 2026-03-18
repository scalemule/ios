import Foundation

public enum ErrorCode: String, Sendable, Codable {
    case unauthorized = "UNAUTHORIZED"
    case forbidden = "FORBIDDEN"
    case notFound = "NOT_FOUND"
    case conflict = "CONFLICT"
    case validationError = "VALIDATION_ERROR"
    case invalidFormat = "INVALID_FORMAT"
    case rateLimited = "RATE_LIMITED"
    case internalError = "INTERNAL_ERROR"
    case networkError = "NETWORK_ERROR"
    case timeout = "TIMEOUT"
    case mfaRequired = "MFA_REQUIRED"
    case mfaSetupRequired = "MFA_SETUP_REQUIRED"
    case emailNotVerified = "EMAIL_NOT_VERIFIED"
    case invalidCredentials = "INVALID_CREDENTIALS"
    case accountLocked = "ACCOUNT_LOCKED"
    case sessionExpired = "SESSION_EXPIRED"
    case unknown = "UNKNOWN"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ErrorCode(rawValue: raw) ?? .unknown
    }
}
