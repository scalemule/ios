import Foundation
import ScaleMuleCore

/// Posts, the app feed and likes (ScaleMule Social, `/v1/social`). Following
/// people, comments and the activity inbox are in `SocialConnections.swift`;
/// deleted posts and restoring them in `SocialDeletedPosts.swift`.
///
/// The feed holds the signed-in person's own posts, every `public` post in the
/// app and `followers` posts from people they follow, newest first. Posts by
/// an account ScaleMule marks synthetic (spam, abuse) stay visible only to
/// their author.
public final class SocialService: ServiceModule, @unchecked Sendable {
    public let client: HTTPClient

    public required init(client: HTTPClient) {
        self.client = client
    }

    public convenience init(app: ScaleMuleApp) {
        self.init(client: app.client)
    }

    // MARK: - Feed

    /// One page of the feed, newest first. `perPage` is capped at 100 by the server.
    /// `scope: .following` holds only posts by people the person follows.
    public func feed(scope: FeedScope = .everyone, page: Int = 1, perPage: Int = 20) async -> ApiResponse<[SocialPost]> {
        await posts(path: "/v1/social/feed", page: page, perPage: perPage, scope: scope == .everyone ? nil : scope)
    }

    /// One page of a person's posts. Your own include private ones.
    public func userPosts(userId: String, page: Int = 1, perPage: Int = 20) async -> ApiResponse<[SocialPost]> {
        await posts(path: "/v1/social/users/\(Self.segment(userId))/posts", page: page, perPage: perPage)
    }

    // MARK: - Posts

    /// Create a post. `content` must be 1-5000 characters.
    ///
    /// `location` is the public point the person chose (see
    /// `ScaleMuleLocation`); never put coordinates in `metadata`: Social
    /// removes them there.
    public func createPost(
        content: String,
        title: String? = nil,
        mediaIds: [String]? = nil,
        mediaUrls: [String]? = nil,
        visibility: PostVisibility = .public,
        tags: [String]? = nil,
        metadata: [String: Any]? = nil,
        location: SharedLocation? = nil
    ) async -> ApiResponse<SocialPost> {
        var body: [String: Any] = [
            "content": content,
            "visibility": visibility.rawValue,
        ]
        if let title { body["title"] = title }
        if let mediaIds { body["media_ids"] = mediaIds }
        if let mediaUrls { body["media_urls"] = mediaUrls }
        if let tags { body["tags"] = tags }
        if let metadata { body["metadata"] = metadata }
        if let location { body["location"] = location.body }

        return await client.request(RequestOptions(
            method: .post,
            path: "/v1/social/posts",
            body: body,
            credential: .accessToken,
            retryable: false
        ))
    }

    public func post(id: String) async -> ApiResponse<SocialPost> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/social/posts/\(Self.segment(id))",
            credential: .accessToken
        ))
    }

    /// Delete one of your own posts. Social hides it at once and keeps it,
    /// with its comments, likes, photos and videos, until
    /// `PostDeletion.restorableUntil` (see `restorePost`); then it removes the
    /// post for good and has its photos and videos deleted. Do not delete the
    /// post's media yourself. Deleting again gives the same answer.
    public func deletePost(id: String) async -> ApiResponse<PostDeletion> {
        await client.request(RequestOptions(
            method: .delete,
            path: "/v1/social/posts/\(Self.segment(id))",
            credential: .accessToken
        ))
    }

    // MARK: - Likes

    public func like(_ target: LikeTarget = .post, id: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .post,
            path: "/v1/social/\(target.rawValue)/\(Self.segment(id))/like",
            credential: .accessToken
        ))
    }

    public func unlike(_ target: LikeTarget = .post, id: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .delete,
            path: "/v1/social/\(target.rawValue)/\(Self.segment(id))/like",
            credential: .accessToken
        ))
    }

    // MARK: - Views

    /// Count that the signed-in person saw a post (Social's view counter:
    /// total views and unique viewers per post). Call once per post shown;
    /// `MediaPosts.SocialFeedModel` does it after a post was on screen for a
    /// second.
    public func recordView(_ target: LikeTarget = .post, id: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .post,
            path: "/v1/social/\(target.rawValue)/\(Self.segment(id))/views",
            body: [:],
            credential: .accessToken,
            retryable: false
        ))
    }

    // MARK: - Private

    private func posts(path: String, page: Int, perPage: Int, scope: FeedScope? = nil) async -> ApiResponse<[SocialPost]> {
        var query = ["page": String(max(page, 1)), "per_page": String(min(max(perPage, 1), 100))]
        if let scope { query["scope"] = scope.rawValue }
        let result: ApiResponse<PostsEnvelope> = await client.request(RequestOptions(
            method: .get,
            path: path,
            query: query,
            credential: .accessToken
        ))
        switch result {
        case .success(let envelope): return .success(envelope.posts)
        case .failure(let error): return .failure(error)
        }
    }

    static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? value
    }
}
