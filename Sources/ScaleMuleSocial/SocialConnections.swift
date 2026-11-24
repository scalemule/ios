import Foundation
import ScaleMuleCore

// Following people, comments on posts and the activity inbox
// (ScaleMule Social, `/v1/social`).

/// Which posts a feed page holds.
public enum FeedScope: String, Sendable {
    /// Every public post, plus followers-only posts of people you follow.
    case everyone = "all"
    /// Only posts by people you follow.
    case following
}

/// How the signed-in person and another person are connected.
public struct FollowStatus: Sendable, Decodable, Equatable {
    /// The signed-in person follows them.
    public let isFollowing: Bool
    /// They follow the signed-in person.
    public let isFollowedBy: Bool
    /// How many people follow them; nil when the server did not say.
    public let followersCount: Int?
    /// How many people they follow; nil when the server did not say.
    public let followingCount: Int?

    public init(isFollowing: Bool, isFollowedBy: Bool, followersCount: Int? = nil, followingCount: Int? = nil) {
        self.isFollowing = isFollowing
        self.isFollowedBy = isFollowedBy
        self.followersCount = followersCount
        self.followingCount = followingCount
    }

    private enum CodingKeys: String, CodingKey {
        case isFollowing = "is_following"
        case isFollowedBy = "is_followed_by"
        case followersCount = "followers_count"
        case followingCount = "following_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isFollowing = try c.decodeIfPresent(Bool.self, forKey: .isFollowing) ?? false
        isFollowedBy = try c.decodeIfPresent(Bool.self, forKey: .isFollowedBy) ?? false
        followersCount = try? c.decodeIfPresent(Int.self, forKey: .followersCount)
        followingCount = try? c.decodeIfPresent(Int.self, forKey: .followingCount)
    }
}

/// One person in a followers or following list. Their name and photo come
/// from `PublicProfiles`.
public struct FollowEntry: Sendable, Decodable, Identifiable, Equatable {
    public let userId: String
    /// ISO 8601 timestamp.
    public let followedAt: String?
    public var id: String { userId }

    public init(userId: String, followedAt: String? = nil) {
        self.userId = userId
        self.followedAt = followedAt
    }

    private enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case followedAt = "followed_at"
    }
}

/// A comment on a post.
public struct SocialComment: Sendable, Decodable, Identifiable, Equatable {
    public let id: String
    public let postId: String
    public let userId: String
    /// The comment this one answers, for replies.
    public let parentCommentId: String?
    public let content: String
    public let likesCount: Int
    /// ISO 8601 timestamp.
    public let createdAt: String

    public init(id: String, postId: String, userId: String, parentCommentId: String? = nil, content: String, likesCount: Int = 0, createdAt: String) {
        self.id = id
        self.postId = postId
        self.userId = userId
        self.parentCommentId = parentCommentId
        self.content = content
        self.likesCount = likesCount
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, content
        case postId = "post_id"
        case userId = "user_id"
        case parentCommentId = "parent_comment_id"
        case likesCount = "likes_count"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        postId = try c.decodeIfPresent(String.self, forKey: .postId) ?? ""
        userId = try c.decode(String.self, forKey: .userId)
        parentCommentId = try c.decodeIfPresent(String.self, forKey: .parentCommentId).flatMap { $0.isEmpty ? nil : $0 }
        content = SocialText.unescape(try c.decodeIfPresent(String.self, forKey: .content) ?? "")
        likesCount = try c.decodeIfPresent(Int.self, forKey: .likesCount) ?? 0
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }

    public var createdDate: Date? { SocialDate.parse(createdAt) }
}

/// Something that happened to the signed-in person: someone followed them,
/// liked their post, commented on it or answered their comment.
public struct SocialActivity: Sendable, Decodable, Identifiable, Equatable {
    public enum Kind: String, Sendable {
        case follow, like, comment, reply
        /// A kind this SDK version does not know; show it plainly or skip it.
        case other
    }

    public let id: String
    /// The server's name for what happened ("follow", "like", "comment", "reply").
    public let type: String
    /// Who did it.
    public let actorUserId: String
    /// What it was done to ("post"), when there is a target.
    public let targetType: String?
    public let targetId: String?
    public let metadata: [String: AnyCodable]?
    public let isRead: Bool
    /// ISO 8601 timestamp.
    public let createdAt: String

    public init(id: String, type: String, actorUserId: String, targetType: String? = nil, targetId: String? = nil, metadata: [String: AnyCodable]? = nil, isRead: Bool = false, createdAt: String) {
        self.id = id
        self.type = type
        self.actorUserId = actorUserId
        self.targetType = targetType
        self.targetId = targetId
        self.metadata = metadata
        self.isRead = isRead
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, metadata
        case type = "activity_type"
        case actorUserId = "actor_user_id"
        case targetType = "target_type"
        case targetId = "target_id"
        case isRead = "is_read"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        actorUserId = try c.decodeIfPresent(String.self, forKey: .actorUserId) ?? ""
        targetType = try c.decodeIfPresent(String.self, forKey: .targetType)
        targetId = try c.decodeIfPresent(String.self, forKey: .targetId).flatMap { $0.isEmpty ? nil : $0 }
        isRead = try c.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        // The server sends metadata as an object, or as that object's JSON text.
        if let object = try? c.decodeIfPresent([String: AnyCodable].self, forKey: .metadata) {
            metadata = object
        } else if let text = try? c.decodeIfPresent(String.self, forKey: .metadata),
                  let data = text.data(using: .utf8),
                  let object = try? JSONDecoder().decode([String: AnyCodable].self, from: data) {
            metadata = object
        } else {
            metadata = nil
        }
    }

    public var kind: Kind { Kind(rawValue: type) ?? .other }
    public var createdDate: Date? { SocialDate.parse(createdAt) }

    /// The post it is about (a like, comment or reply).
    public var postId: String? { targetType == "post" ? targetId : nil }

    /// The comment written, for comments and replies.
    public var commentId: String? { metadata?["comment_id"]?.value as? String }

    /// The start of the comment's text, for comments and replies.
    public var commentText: String? {
        (metadata?["text"]?.value as? String).map(SocialText.unescape).flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension SocialService {
    // MARK: - Following

    /// Follow someone. Following them again changes nothing.
    public func follow(userId: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .post,
            path: "/v1/social/users/\(Self.segment(userId))/follow",
            credential: .accessToken
        ))
    }

    public func unfollow(userId: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .delete,
            path: "/v1/social/users/\(Self.segment(userId))/follow",
            credential: .accessToken
        ))
    }

    /// Whether you follow them and they follow you, and how many followers
    /// and followed people they have.
    public func followStatus(userId: String) async -> ApiResponse<FollowStatus> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/social/users/\(Self.segment(userId))/follow-status",
            credential: .accessToken
        ))
    }

    /// One page of the people who follow `userId`, newest first.
    public func followers(userId: String, page: Int = 1, perPage: Int = 50) async -> ApiResponse<[FollowEntry]> {
        let result: ApiResponse<FollowersEnvelope> = await client.request(RequestOptions(
            method: .get,
            path: "/v1/social/users/\(Self.segment(userId))/followers",
            query: Self.paging(page, perPage),
            credential: .accessToken
        ))
        return result.map { $0.followers }
    }

    /// One page of the people `userId` follows, newest first.
    public func following(userId: String, page: Int = 1, perPage: Int = 50) async -> ApiResponse<[FollowEntry]> {
        let result: ApiResponse<FollowingEnvelope> = await client.request(RequestOptions(
            method: .get,
            path: "/v1/social/users/\(Self.segment(userId))/following",
            query: Self.paging(page, perPage),
            credential: .accessToken
        ))
        return result.map { $0.following }
    }

    // MARK: - Comments

    /// One page of a post's comments. Comments by people you blocked (or who
    /// blocked you) are left out by the server.
    public func comments(postId: String, page: Int = 1, perPage: Int = 30) async -> ApiResponse<[SocialComment]> {
        let result: ApiResponse<CommentsEnvelope> = await client.request(RequestOptions(
            method: .get,
            path: "/v1/social/posts/\(Self.segment(postId))/comments",
            query: Self.paging(page, perPage),
            credential: .accessToken
        ))
        return result.map { $0.comments }
    }

    /// Comment on a post (1-2000 characters). `replyingTo` is the comment being answered.
    public func addComment(postId: String, content: String, replyingTo parentCommentId: String? = nil) async -> ApiResponse<SocialComment> {
        var body: [String: Any] = ["content": content]
        if let parentCommentId { body["parent_comment_id"] = parentCommentId }
        return await client.request(RequestOptions(
            method: .post,
            path: "/v1/social/posts/\(Self.segment(postId))/comments",
            body: body,
            credential: .accessToken,
            retryable: false
        ))
    }

    /// Delete a comment: your own, or any comment on your own post.
    public func deleteComment(postId: String, commentId: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .delete,
            path: "/v1/social/posts/\(Self.segment(postId))/comments/\(Self.segment(commentId))",
            credential: .accessToken
        ))
    }

    // MARK: - Activity inbox

    /// What happened to the signed-in person lately, newest first.
    public func activity(limit: Int = 50, unreadOnly: Bool = false) async -> ApiResponse<[SocialActivity]> {
        var query = ["limit": String(min(max(limit, 1), 200))]
        if unreadOnly { query["unread_only"] = "true" }
        let result: ApiResponse<ActivityEnvelope> = await client.request(RequestOptions(
            method: .get,
            path: "/v1/social/activity",
            query: query,
            credential: .accessToken
        ))
        return result.map { $0.activities }
    }

    /// How many activity entries are unread (the inbox badge).
    public func unreadActivityCount() async -> ApiResponse<Int> {
        let result: ApiResponse<UnreadEnvelope> = await client.request(RequestOptions(
            method: .get,
            path: "/v1/social/activity/unread-count",
            credential: .accessToken
        ))
        return result.map { $0.unread }
    }

    public func markActivityRead(id: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .patch,
            path: "/v1/social/activity/\(Self.segment(id))/read",
            credential: .accessToken
        ))
    }

    public func markAllActivityRead() async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .patch,
            path: "/v1/social/activity/read-all",
            credential: .accessToken
        ))
    }

    private static func paging(_ page: Int, _ perPage: Int) -> [String: String] {
        ["page": String(max(page, 1)), "per_page": String(min(max(perPage, 1), 100))]
    }
}

extension ApiResponse {
    /// The same response with its value changed.
    func map<U>(_ transform: (T) -> U) -> ApiResponse<U> {
        switch self {
        case .success(let value): return .success(transform(value))
        case .failure(let error): return .failure(error)
        }
    }
}

struct FollowersEnvelope: Decodable, Sendable { let followers: [FollowEntry] }
struct FollowingEnvelope: Decodable, Sendable { let following: [FollowEntry] }
struct CommentsEnvelope: Decodable, Sendable { let comments: [SocialComment] }
struct ActivityEnvelope: Decodable, Sendable { let activities: [SocialActivity] }
struct UnreadEnvelope: Decodable, Sendable {
    let unread: Int

    private enum CodingKeys: String, CodingKey { case unread, count }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unread = try c.decodeIfPresent(Int.self, forKey: .unread) ?? c.decodeIfPresent(Int.self, forKey: .count) ?? 0
    }
}

enum SocialDate {
    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Social stores people's text HTML-escaped (`it&#x27;s`); people see the text.
enum SocialText {
    static func unescape(_ value: String) -> String {
        guard value.contains("&") else { return value }
        return value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#x2F;", with: "/")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
