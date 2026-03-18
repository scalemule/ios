import Foundation

public struct LoginHistoryResult: Sendable, Decodable {
    public let entries: [LoginHistoryEntry]
    public let total: Int
    public let page: Int
    public let perPage: Int

    private enum CodingKeys: String, CodingKey {
        case entries
        case total
        case page
        case perPage = "per_page"
    }
}

public struct LoginHistoryEntry: Sendable, Decodable {
    public let id: String?
    public let userId: String?
    public let ipAddress: String?
    public let userAgent: String?
    public let success: Bool?
    public let failureReason: String?
    public let location: String?
    public let deviceFingerprint: String?
    public let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case ipAddress = "ip_address"
        case userAgent = "user_agent"
        case success
        case failureReason = "failure_reason"
        case location
        case deviceFingerprint = "device_fingerprint"
        case createdAt = "created_at"
    }
}

public struct LoginActivitySummary: Sendable, Decodable {
    public let totalLogins: Int?
    public let successfulLogins: Int?
    public let failedLogins: Int?
    public let uniqueIps: Int?
    public let uniqueDevices: Int?
    public let lastLoginAt: String?
    public let lastFailedAt: String?

    private enum CodingKeys: String, CodingKey {
        case totalLogins = "total_logins"
        case successfulLogins = "successful_logins"
        case failedLogins = "failed_logins"
        case uniqueIps = "unique_ips"
        case uniqueDevices = "unique_devices"
        case lastLoginAt = "last_login_at"
        case lastFailedAt = "last_failed_at"
    }
}
