import Foundation
import ScaleMuleCore

/// One person the signed-in person blocked.
public struct BlockedIdentity: Sendable, Decodable, Identifiable, Equatable {
    public let blockedIdentityId: String
    public let scope: String
    public let createdAt: String?

    public var id: String { blockedIdentityId }

    private enum CodingKeys: String, CodingKey {
        case blockedIdentityId = "blocked_identity_id"
        case scope
        case createdAt = "created_at"
    }
}

public struct BlockList: Sendable, Decodable, Equatable {
    public let blocks: [BlockedIdentity]
    public let page: Int
    public let perPage: Int
    public let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case blocks, page
        case perPage = "per_page"
        case hasMore = "has_more"
    }
}

/// Block, unblock and list the people the signed-in person blocked
/// (`/v1/social-policy`). The blocker is always the signed-in person. The
/// Social feed and profiles already leave out people blocked in either
/// direction (within about 30 seconds of a new block).
public final class BlockService: ServiceModule, @unchecked Sendable {
    public let client: HTTPClient

    public required init(client: HTTPClient) {
        self.client = client
    }

    public convenience init(app: ScaleMuleApp) {
        self.init(client: app.client)
    }

    public func block(_ blockedUserId: String, by userId: String, reason: String? = nil) async -> ApiResponse<EmptyResponse> {
        var body: [String: Any] = [
            "blocker_identity_id": userId,
            "blocked_identity_id": blockedUserId,
            "scope": "global_app",
        ]
        if let reason { body["reason"] = reason }
        return await client.requestVoid(RequestOptions(method: .post, path: "/v1/social-policy/block", body: body, credential: .accessToken))
    }

    /// The signed-in person's blocks, newest first.
    public func list(page: Int = 1, perPage: Int = 50) async -> ApiResponse<BlockList> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/social-policy/blocks",
            query: ["page": String(max(page, 1)), "per_page": String(min(max(perPage, 1), 100))],
            credential: .accessToken
        ))
    }

    public func unblock(_ blockedUserId: String, by userId: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .post,
            path: "/v1/social-policy/unblock",
            body: ["blocker_identity_id": userId, "blocked_identity_id": blockedUserId, "scope": "global_app"],
            credential: .accessToken
        ))
    }
}
