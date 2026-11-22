import Foundation
import ScaleMuleCore

/// Block or unblock a person for the signed-in person (`/v1/social-policy`).
///
/// The server cannot list blocks back and does not filter feeds by them:
/// keep the list in the app and hide blocked people's content yourself.
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

    public func unblock(_ blockedUserId: String, by userId: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .post,
            path: "/v1/social-policy/unblock",
            body: ["blocker_identity_id": userId, "blocked_identity_id": blockedUserId, "scope": "global_app"],
            credential: .accessToken
        ))
    }
}
