import Foundation
import ScaleMuleCore

public final class AuthLoginHistorySubService: Sendable {
    private let client: HTTPClient

    init(client: HTTPClient) {
        self.client = client
    }

    // MARK: - A31: List Login History

    public func list(
        page: Int? = nil,
        perPage: Int? = nil,
        success: Bool? = nil
    ) async -> ApiResponse<LoginHistoryResult> {
        var query: [String: String] = [:]
        if let page { query["page"] = String(page) }
        if let perPage { query["per_page"] = String(perPage) }
        if let success { query["success"] = String(success) }

        return await client.request(RequestOptions(
            method: .get,
            path: "/v1/auth/login-history",
            query: query.isEmpty ? nil : query,
            credential: .sessionToken
        ))
    }

    // MARK: - A32: Get Login Activity Summary

    public func getSummary() async -> ApiResponse<LoginActivitySummary> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/auth/login-activity",
            credential: .sessionToken
        ))
    }
}
