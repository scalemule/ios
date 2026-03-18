import Foundation

public struct ListSessionsResult: Sendable, Decodable {
    public let sessions: [SessionInfo]
    public let total: Int
}

public struct SessionInfo: Sendable, Decodable {
    public let id: String
    public let userId: String?
    public let ipAddress: String?
    public let userAgent: String?
    public let lastActiveAt: String?
    public let createdAt: String?
    public let expiresAt: String?
    public let isCurrent: Bool?

    private enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case ipAddress = "ip_address"
        case userAgent = "user_agent"
        case lastActiveAt = "last_active_at"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case isCurrent = "is_current"
    }
}

public struct RevokeSessionResult: Sendable, Decodable {
    public let message: String
}

public struct RevokeOtherSessionsResult: Sendable, Decodable {
    public let message: String
    public let revokedCount: Int?

    private enum CodingKeys: String, CodingKey {
        case message
        case revokedCount = "revoked_count"
    }
}

public struct DeviceInfo: Sendable, Decodable {
    public let id: String
    public let userId: String?
    public let fingerprint: String?
    public let name: String?
    public let trusted: Bool?
    public let blocked: Bool?
    public let lastSeenAt: String?
    public let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case fingerprint
        case name
        case trusted
        case blocked
        case lastSeenAt = "last_seen_at"
        case createdAt = "created_at"
    }
}

public struct DeviceListResult: Sendable, Decodable {
    public let devices: [DeviceInfo]
    public let total: Int
}
