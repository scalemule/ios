import Foundation
import ScaleMuleCore

/// Who can see a post.
public enum PostVisibility: String, Sendable, Codable {
    /// Everyone signed in to the app (the app's public feed).
    case `public`
    /// The author's followers.
    case followers
    /// Only the author.
    case `private`
    /// Members of the listed groups.
    case groups
}

/// A post in the Social service. `mediaIds` usually hold photo ids from
/// `PhotosService`; `metadata` is the app's own JSON (place, author name, ...).
public struct SocialPost: Sendable, Decodable, Identifiable, Equatable {
    public let id: String
    public let userId: String
    public let content: String
    public let title: String?
    public let mediaUrls: [String]?
    public let mediaIds: [String]?
    public let visibility: PostVisibility
    public let tags: [String]?
    public let metadata: [String: AnyCodable]?
    /// Where the post was, as its author chose to share it.
    public let location: SharedLocation?
    public let likesCount: Int
    /// Whether the signed-in person liked it (`likesCount` already counts
    /// that like); nil when the server did not say.
    public let likedByMe: Bool?
    public let commentsCount: Int
    public let sharesCount: Int
    /// Whether the signed-in person follows the author; nil when the server
    /// did not say (false on your own posts).
    public let viewerFollowsAuthor: Bool?
    /// ISO 8601 timestamp.
    public let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case content, title
        case mediaUrls = "media_urls"
        case mediaIds = "media_ids"
        case visibility, tags, metadata, location
        case likesCount = "likes_count"
        case likedByMe = "liked_by_me"
        case commentsCount = "comments_count"
        case sharesCount = "shares_count"
        case viewerFollowsAuthor = "viewer_follows_author"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = try c.decode(String.self, forKey: .userId)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title)
        mediaUrls = try c.decodeIfPresent([String].self, forKey: .mediaUrls)
        mediaIds = try c.decodeIfPresent([String].self, forKey: .mediaIds)
        visibility = (try? c.decode(PostVisibility.self, forKey: .visibility)) ?? .public
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        metadata = try c.decodeIfPresent([String: AnyCodable].self, forKey: .metadata)
        location = try? c.decodeIfPresent(SharedLocation.self, forKey: .location)
        likesCount = try c.decodeIfPresent(Int.self, forKey: .likesCount) ?? 0
        likedByMe = try? c.decodeIfPresent(Bool.self, forKey: .likedByMe)
        commentsCount = try c.decodeIfPresent(Int.self, forKey: .commentsCount) ?? 0
        sharesCount = try c.decodeIfPresent(Int.self, forKey: .sharesCount) ?? 0
        viewerFollowsAuthor = try? c.decodeIfPresent(Bool.self, forKey: .viewerFollowsAuthor)
        createdAt = try c.decode(String.self, forKey: .createdAt)
    }

    /// `createdAt` as a date, when it parses.
    public var createdDate: Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt)
    }

    /// A string value from `metadata`.
    public func metadataString(_ key: String) -> String? {
        metadata?[key]?.value as? String
    }

    /// A number from `metadata`.
    public func metadataDouble(_ key: String) -> Double? {
        switch metadata?[key]?.value {
        case let double as Double: return double
        case let int as Int: return Double(int)
        default: return nil
        }
    }
}

/// What can be liked.
public enum LikeTarget: String, Sendable {
    case post
    case comment
}

struct PostsEnvelope: Decodable, Sendable {
    let posts: [SocialPost]
}
