import Foundation
import ScaleMuleCore

public struct MfaStatus: Sendable, Decodable {
    public let enabled: Bool
    public let methods: [String]?
    public let backupCodesRemaining: Int?

    private enum CodingKeys: String, CodingKey {
        case enabled
        case methods
        case backupCodesRemaining = "backup_codes_remaining"
    }
}

public struct TotpSetup: Sendable, Decodable {
    public let secret: String
    public let qrCodeUrl: String
    public let otpauthUrl: String?

    private enum CodingKeys: String, CodingKey {
        case secret
        case qrCodeUrl = "qr_code_url"
        case otpauthUrl = "otpauth_url"
    }
}

public struct BackupCodes: Sendable, Decodable {
    public let codes: [String]
}

public struct MfaVerifyResult: Sendable, Decodable {
    public let sessionToken: String?
    public let user: AuthUser?
    public let expiresAt: String?
    public let accessToken: String?
    public let refreshToken: String?
    public let accessTokenExpiresIn: Int?

    private enum CodingKeys: String, CodingKey {
        case sessionToken = "session_token"
        case user
        case expiresAt = "expires_at"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accessTokenExpiresIn = "access_token_expires_in"
    }

    public func toCredentialSet() -> CredentialSet? {
        guard let token = sessionToken, let expiry = expiresAt else { return nil }
        let sessionExpiry = DateFormatting.parseISO8601(expiry) ?? Date().addingTimeInterval(3600)
        let atExpiry = accessTokenExpiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        return CredentialSet(
            sessionToken: token,
            accessToken: accessToken,
            refreshToken: refreshToken,
            sessionExpiresAt: sessionExpiry,
            accessTokenExpiresAt: atExpiry
        )
    }
}

public struct MfaSendCodeResult: Sendable, Decodable {
    public let message: String?
    public let expiresIn: Int?

    private enum CodingKeys: String, CodingKey {
        case message
        case expiresIn = "expires_in"
    }
}

public enum MfaMethod: String, Sendable {
    case totp
    case sms
    case email
    case backupCode = "backup_code"
}

public enum MfaSendChannel: String, Sendable {
    case sms
    case email
}

public enum OtpPurpose: String, Sendable {
    case verifyPhone = "verify_phone"
    case verifyEmail = "verify_email"
    case login
    case passwordReset = "password_reset"
    case changePhone = "change_phone"
}
