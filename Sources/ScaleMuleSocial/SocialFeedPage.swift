import Foundation
import ScaleMuleCore

/// A stable page of the feed. Cursors are opaque post IDs supplied by Social.
public struct SocialFeedPage: Decodable, Sendable {
    public let posts: [SocialPost]
    public let nextCursor: String?
    public let asOf: Int64?
    /// Nil means removals cannot be determined by this response.
    public let removed: [String]?
    public let gap: Bool

    private enum CodingKeys: String, CodingKey {
        case posts, removed, gap
        case nextCursor = "next_cursor"
        case asOf = "as_of"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        posts = try c.decode([SocialPost].self, forKey: .posts)
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        asOf = try c.decodeIfPresent(Int64.self, forKey: .asOf)
        removed = try c.decodeIfPresent([String].self, forKey: .removed)
        gap = try c.decodeIfPresent(Bool.self, forKey: .gap) ?? false
    }
}

extension SocialService {
    /// Read older pages with `before`, or only incoming posts with `after`.
    /// A gap requires a new first page; it must not be joined to old history.
    public func feedPage(
        scope: FeedScope = .everyone, before: String? = nil,
        after: String? = nil, since: Int64? = nil, perPage: Int = 20
    ) async -> ApiResponse<SocialFeedPage> {
        var query = ["per_page": String(min(max(perPage, 1), 100))]
        if scope != .everyone { query["scope"] = scope.rawValue }
        if let before { query["before"] = before }
        if let after { query["after"] = after }
        if let since { query["since"] = String(since) }
        return await client.request(RequestOptions(
            method: .get, path: "/v1/social/feed", query: query, credential: .accessToken
        ))
    }
}
