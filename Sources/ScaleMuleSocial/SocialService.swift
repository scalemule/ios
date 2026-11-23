import Foundation
import ScaleMuleCore

/// Posts, the app feed and likes (ScaleMule Social, `/v1/social`).
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
    public func feed(page: Int = 1, perPage: Int = 20) async -> ApiResponse<[SocialPost]> {
        await posts(path: "/v1/social/feed", page: page, perPage: perPage)
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

    /// Delete one of your own posts.
    public func deletePost(id: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
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

    // MARK: - Private

    private func posts(path: String, page: Int, perPage: Int) async -> ApiResponse<[SocialPost]> {
        let result: ApiResponse<PostsEnvelope> = await client.request(RequestOptions(
            method: .get,
            path: path,
            query: ["page": String(max(page, 1)), "per_page": String(min(max(perPage, 1), 100))],
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
