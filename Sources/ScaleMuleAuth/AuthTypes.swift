import Foundation
import ScaleMuleCore

// MARK: - Register

/// Register returns User only — NO session. Firehosy flow: register -> verify email -> login.
public struct RegisterResult: Sendable, Decodable {
    public let user: AuthUser
}

// MARK: - Login

/// Full login response: session + user + optional JWT tokens + device/risk info.
public struct LoginResult: Sendable, Decodable {
    public let sessionToken: String
    public let user: AuthUser
    public let expiresAt: String
    public let absoluteExpiresAt: String?
    public let accessToken: String?
    public let refreshToken: String?
    public let accessTokenExpiresIn: Int?
    public let device: LoginDeviceInfo?
    public let risk: LoginRiskInfo?

    private enum CodingKeys: String, CodingKey {
        case sessionToken = "session_token"
        case user
        case expiresAt = "expires_at"
        case absoluteExpiresAt = "absolute_expires_at"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accessTokenExpiresIn = "access_token_expires_in"
        case device
        case risk
    }

    public func toCredentialSet() -> CredentialSet {
        let sessionExpiry = DateFormatting.parseISO8601(expiresAt) ?? Date().addingTimeInterval(3600)
        let absExpiry = absoluteExpiresAt.flatMap { DateFormatting.parseISO8601($0) }
        let atExpiry = accessTokenExpiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        return CredentialSet(
            sessionToken: sessionToken,
            accessToken: accessToken,
            refreshToken: refreshToken,
            sessionExpiresAt: sessionExpiry,
            absoluteExpiresAt: absExpiry,
            accessTokenExpiresAt: atExpiry
        )
    }
}

public struct LoginDeviceInfo: Sendable, Decodable, Equatable {
    public let deviceId: String?
    public let trusted: Bool?
    public let fingerprint: String?

    private enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case trusted
        case fingerprint
    }
}

public struct LoginRiskInfo: Sendable, Decodable, Equatable {
    public let level: String?
    public let factors: [String]?
    public let requiresMfa: Bool?

    private enum CodingKeys: String, CodingKey {
        case level
        case factors
        case requiresMfa = "requires_mfa"
    }
}

// MARK: - Refresh Session

/// Refresh session returns ONLY session_token + expires_at — NOT a full session.
public struct RefreshSessionResult: Sendable, Decodable {
    public let sessionToken: String
    public let expiresAt: String

    private enum CodingKeys: String, CodingKey {
        case sessionToken = "session_token"
        case expiresAt = "expires_at"
    }
}

// MARK: - OAuth Callback

public struct OAuthCallbackResult: Sendable, Decodable {
    public let sessionToken: String
    public let user: AuthUser
    public let expiresAt: String
    public let isNewUser: Bool

    private enum CodingKeys: String, CodingKey {
        case sessionToken = "session_token"
        case user
        case expiresAt = "expires_at"
        case isNewUser = "is_new_user"
    }

    public func toCredentialSet() -> CredentialSet {
        let sessionExpiry = DateFormatting.parseISO8601(expiresAt) ?? Date().addingTimeInterval(3600)
        return CredentialSet(
            sessionToken: sessionToken,
            sessionExpiresAt: sessionExpiry
        )
    }
}

// MARK: - Verify Email

public struct VerifyEmailResult: Sendable, Decodable {
    public let verified: Bool
    public let sessionToken: String?
    public let user: AuthUser?
    public let expiresAt: String?

    private enum CodingKeys: String, CodingKey {
        case verified
        case sessionToken = "session_token"
        case user
        case expiresAt = "expires_at"
    }

    /// When auto_session is enabled, creates a sessionOnly CredentialSet.
    public func toCredentialSet() -> CredentialSet? {
        guard let token = sessionToken, let expiry = expiresAt else { return nil }
        let sessionExpiry = DateFormatting.parseISO8601(expiry) ?? Date().addingTimeInterval(3600)
        return CredentialSet(
            sessionToken: token,
            sessionExpiresAt: sessionExpiry
        )
    }
}

// MARK: - Token Refresh

public struct RefreshAccessTokenResult: Sendable, Decodable {
    public let accessToken: String
    public let tokenType: String
    public let expiresIn: Int

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

// MARK: - Generic Message Response

public struct MessageResult: Sendable, Decodable {
    public let message: String
}

// MARK: - Change Phone

public struct ChangePhoneResult: Sendable, Decodable {
    public let message: String
    public let expiresInSeconds: Int?

    private enum CodingKeys: String, CodingKey {
        case message
        case expiresInSeconds = "expires_in_seconds"
    }
}

// MARK: - Phone OTP

public struct PhoneOtpResult: Sendable, Decodable {
    public let message: String?
    public let expiresIn: Int?

    private enum CodingKeys: String, CodingKey {
        case message
        case expiresIn = "expires_in"
    }
}

// MARK: - Data Export

public struct DataExportResult: Sendable, Decodable {
    public let data: ExportData
}

public struct ExportData: Sendable, Decodable {
    public let user: AuthUser?
    public let sessions: [String: AnyCodable]?
    public let devices: [String: AnyCodable]?
}
