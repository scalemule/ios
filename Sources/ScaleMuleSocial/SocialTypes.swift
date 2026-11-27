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
    /// The author as they are now. Social fills it on every page; nil from an
    /// older server or when Social could not look the author up in time.
    public let author: PostAuthor?
    /// The shared entity (a pet, a team) the post belongs to; nil for a
    /// person's own post. `userId` and `author` are then the entity's: Social
    /// never says which person made an entity's post.
    public let entityId: String?
    /// For an entity's post: whether the signed-in person made it. nil for a
    /// person's own post (compare `userId` there).
    public let postedByViewer: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, author
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
        case entityId = "entity_id"
        case postedByViewer = "posted_by_viewer"
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
        author = (try? c.decodeIfPresent(PostAuthor.self, forKey: .author)) ?? nil
        entityId = (try? c.decodeIfPresent(String.self, forKey: .entityId)) ?? nil
        postedByViewer = (try? c.decodeIfPresent(Bool.self, forKey: .postedByViewer)) ?? nil
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

/// Who wrote a post or comment, as they are now (Social looks it up for
/// each page, so a renamed person's old posts show the new name).
public struct PostAuthor: Sendable, Decodable, Equatable {
    public let id: String
    /// The full name as the person typed it; nil when they gave none.
    public let name: String?
    /// The profile photo; only an `https` link is kept.
    public let avatarURL: URL?
    /// The entity's kind ("pet") when the author is a shared entity; nil for
    /// a person.
    public let kind: String?

    public init(id: String, name: String?, avatarURL: URL?, kind: String? = nil) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
        self.kind = kind
    }

    /// The first word of the name ("Maya" of "Maya Okafor").
    public var firstName: String? {
        name?.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind
        case avatarURL = "avatar_url"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // Auth stores profile text HTML-escaped; people see the text.
        let typed = (try c.decodeIfPresent(String.self, forKey: .name))
            .map(SocialText.unescape)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        name = (typed?.isEmpty ?? true) ? nil : typed
        let link = (try c.decodeIfPresent(String.self, forKey: .avatarURL))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        avatarURL = link.flatMap(URL.init(string:)).flatMap { $0.scheme?.lowercased() == "https" && $0.host != nil ? $0 : nil }
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil
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
