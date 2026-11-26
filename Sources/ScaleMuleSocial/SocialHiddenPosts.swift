import Foundation
import ScaleMuleCore

// Hiding a post and showing it again (ScaleMule Social, `/v1/social`).
//
// A hidden post is gone for everyone, its author's own profile and feed
// included: it is in no feed, "not found" by id, and its photos and videos
// are private. Social keeps it, with its comments and likes, for as long as
// it stays hidden; there is no end date. Its author sees it only in the list
// of hidden posts and can show it again or delete it from there.
//
// Hide is not delete: `SocialService.deletePost` on a hidden (or live) post
// follows the app's delete rules, and where the app lets only its team
// restore, a deleted post is gone for its author (`PostDeletion.restorableBy`).

/// What Social answered when a post was hidden.
public struct PostHiding: Sendable, Decodable, Equatable {
    public let hidden: Bool
    /// When it was hidden (the first time, if asked again).
    public let hiddenAt: Date?

    public init(hidden: Bool = true, hiddenAt: Date? = nil) {
        self.hidden = hidden
        self.hiddenAt = hiddenAt
    }

    private enum CodingKeys: String, CodingKey {
        case hidden
        case hiddenAt = "hidden_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hidden = (try? c.decodeIfPresent(Bool.self, forKey: .hidden)) ?? true
        hiddenAt = (try? c.decodeIfPresent(String.self, forKey: .hiddenAt)).flatMap(SocialDate.parse)
    }
}

/// A post its author hid.
public struct HiddenPost: Sendable, Decodable, Identifiable, Equatable {
    public let post: SocialPost
    public let hiddenAt: Date?

    public var id: String { post.id }

    public init(post: SocialPost, hiddenAt: Date? = nil) {
        self.post = post
        self.hiddenAt = hiddenAt
    }

    private enum CodingKeys: String, CodingKey {
        case hiddenAt = "hidden_at"
    }

    /// Social sends the post's own fields and the date side by side.
    public init(from decoder: Decoder) throws {
        post = try SocialPost(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hiddenAt = (try? c.decodeIfPresent(String.self, forKey: .hiddenAt)).flatMap(SocialDate.parse)
    }
}

/// One page of the signed-in person's hidden posts, most recently hidden first.
public struct HiddenPostsPage: Sendable, Decodable, Equatable {
    public let posts: [HiddenPost]

    public init(posts: [HiddenPost]) {
        self.posts = posts
    }

    private enum CodingKeys: String, CodingKey {
        case posts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        posts = try c.decodeIfPresent([HiddenPost].self, forKey: .posts) ?? []
    }
}

extension SocialService {
    /// Hide one of your posts: it is gone for everyone, your own profile and
    /// feed included, until you show it again. Hiding a post that is already
    /// hidden answers the same.
    ///
    /// Refusals (`error.userFacingMessage` says which): 403 when the app does
    /// not offer hiding, 404 when the post is not yours or is gone.
    public func hidePost(id: String) async -> ApiResponse<PostHiding> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/social/posts/\(Self.segment(id))/hide",
            credential: .accessToken
        ))
    }

    /// Show a hidden post again: it returns to feeds and your page with its
    /// comments, likes, photos and videos. A post that is already showing
    /// answers with the post.
    ///
    /// Refusals: 404 when it is not yours or was deleted, 403 when it was
    /// taken down while hidden.
    public func unhidePost(id: String) async -> ApiResponse<SocialPost> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/social/posts/\(Self.segment(id))/unhide",
            credential: .accessToken
        ))
    }

    /// The signed-in person's hidden posts, most recently hidden first.
    /// `perPage` is capped at 100 by the server.
    public func hiddenPosts(page: Int = 1, perPage: Int = 30) async -> ApiResponse<HiddenPostsPage> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/social/posts/hidden",
            query: ["page": String(max(page, 1)), "per_page": String(min(max(perPage, 1), 100))],
            credential: .accessToken
        ))
    }
}
