import Foundation
import ScaleMuleCore

public final class AuthSessionsSubService: Sendable {
    private let client: HTTPClient

    init(client: HTTPClient) {
        self.client = client
    }

    // MARK: - A24: List Sessions

    public func list() async -> ApiResponse<ListSessionsResult> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/auth/sessions",
            credential: .sessionToken
        ))
    }

    // MARK: - A25: Revoke Session

    public func revoke(sessionId: String) async -> ApiResponse<RevokeSessionResult> {
        await client.request(RequestOptions(
            method: .delete,
            path: "/v1/auth/sessions/\(sessionId)",
            credential: .sessionToken
        ))
    }

    // MARK: - A26: Revoke All Other Sessions

    public func revokeAll() async -> ApiResponse<RevokeOtherSessionsResult> {
        await client.request(RequestOptions(
            method: .delete,
            path: "/v1/auth/sessions/others",
            credential: .sessionToken
        ))
    }
}
