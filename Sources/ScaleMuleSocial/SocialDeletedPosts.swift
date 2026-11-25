import Foundation
import ScaleMuleCore

// Deleting a post, the deleted posts that are still kept, and bringing one
// back (ScaleMule Social, `/v1/social`).
//
// When its author deletes a post, Social hides it at once and keeps it, with
// its comments, likes, photos and videos, for as many days as the app decided
// (30 unless the app set something else). Until that date it can be restored;
// after it Social removes the post for good and has its photos and videos
// deleted in ScaleMule Photos and Video. An app never deletes a post's media
// itself: a restored post would come back without its picture.

/// Who may bring a deleted post back in this app.
public enum PostRestorer: String, Sendable, Equatable {
    /// The person who wrote and deleted it.
    case author
    /// Only the app's team.
    case team
    /// Nobody: a deleted post stays deleted.
    case nobody

    /// A value this SDK version does not know counts as `nobody`: the app
    /// offers no Restore it cannot be sure of.
    init(serverValue: String?) {
        self = serverValue.flatMap(PostRestorer.init(rawValue:)) ?? .nobody
    }
}

/// What Social answered when a post was deleted.
public struct PostDeletion: Sendable, Decodable, Equatable {
    public let deleted: Bool
    /// Until when the post can be restored; nil when it is gone now (the app
    /// keeps deleted posts for 0 days).
    public let restorableUntil: Date?
    /// Who may restore it until then.
    public let restorableBy: PostRestorer

    public init(deleted: Bool = true, restorableUntil: Date? = nil, restorableBy: PostRestorer = .nobody) {
        self.deleted = deleted
        self.restorableUntil = restorableUntil
        self.restorableBy = restorableBy
    }

    private enum CodingKeys: String, CodingKey {
        case deleted
        case restorableUntil = "restorable_until"
        case restorableBy = "restorable_by"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deleted = (try? c.decodeIfPresent(Bool.self, forKey: .deleted)) ?? true
        restorableUntil = (try? c.decodeIfPresent(String.self, forKey: .restorableUntil)).flatMap(SocialDate.parse)
        restorableBy = PostRestorer(serverValue: try? c.decodeIfPresent(String.self, forKey: .restorableBy))
    }

    /// The person who deleted it can still bring it back themselves.
    public func canBeRestoredByAuthor(now: Date = Date()) -> Bool {
        guard restorableBy == .author, let restorableUntil else { return false }
        return restorableUntil > now
    }

    /// How many days the author has to restore it ("You can restore it for
    /// 30 days"); nil when they cannot. A part of a day counts as a day.
    public func daysToRestore(now: Date = Date()) -> Int? {
        guard canBeRestoredByAuthor(now: now), let restorableUntil else { return nil }
        return RestoreWindow.days(from: now, until: restorableUntil)
    }
}

/// A post its author deleted that Social still keeps.
public struct DeletedPost: Sendable, Decodable, Identifiable, Equatable {
    public let post: SocialPost
    public let deletedAt: Date?
    /// After this the post is removed for good, with its photos and videos.
    public let restorableUntil: Date?

    public var id: String { post.id }

    public init(post: SocialPost, deletedAt: Date? = nil, restorableUntil: Date? = nil) {
        self.post = post
        self.deletedAt = deletedAt
        self.restorableUntil = restorableUntil
    }

    private enum CodingKeys: String, CodingKey {
        case deletedAt = "deleted_at"
        case restorableUntil = "restorable_until"
    }

    /// Social sends the post's own fields and the two dates side by side.
    public init(from decoder: Decoder) throws {
        post = try SocialPost(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deletedAt = (try? c.decodeIfPresent(String.self, forKey: .deletedAt)).flatMap(SocialDate.parse)
        restorableUntil = (try? c.decodeIfPresent(String.self, forKey: .restorableUntil)).flatMap(SocialDate.parse)
    }

    /// Days until it is removed for good; a part of a day counts as a day,
    /// 0 once the date has passed (or was never said).
    public func daysLeft(now: Date = Date()) -> Int {
        restorableUntil.map { RestoreWindow.days(from: now, until: $0) } ?? 0
    }
}

/// One page of the signed-in person's deleted posts, most recently deleted first.
public struct DeletedPostsPage: Sendable, Decodable, Equatable {
    public let posts: [DeletedPost]
    /// Who may restore them in this app.
    public let restorableBy: PostRestorer

    public init(posts: [DeletedPost], restorableBy: PostRestorer) {
        self.posts = posts
        self.restorableBy = restorableBy
    }

    private enum CodingKeys: String, CodingKey {
        case posts
        case restorableBy = "restorable_by"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        posts = try c.decodeIfPresent([DeletedPost].self, forKey: .posts) ?? []
        restorableBy = PostRestorer(serverValue: try? c.decodeIfPresent(String.self, forKey: .restorableBy))
    }
}

enum RestoreWindow {
    /// Whole days from `now` until `end`, rounded up; never below 0.
    static func days(from now: Date, until end: Date) -> Int {
        let seconds = end.timeIntervalSince(now)
        guard seconds > 0 else { return 0 }
        return Int((seconds / 86_400).rounded(.up))
    }
}

extension SocialService {
    /// The signed-in person's deleted posts that can still be restored, most
    /// recently deleted first. `perPage` is capped at 100 by the server.
    public func deletedPosts(page: Int = 1, perPage: Int = 30) async -> ApiResponse<DeletedPostsPage> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/social/posts/deleted",
            query: ["page": String(max(page, 1)), "per_page": String(min(max(perPage, 1), 100))],
            credential: .accessToken
        ))
    }

    /// Bring back a post you deleted: it returns to feeds and your page with
    /// its comments, likes, photos and videos. Restoring a post that is
    /// already back answers with the post.
    ///
    /// Refusals (`error.userFacingMessage` says which): 403 when the app does
    /// not let authors restore or the post was taken down, 404 when it is not
    /// yours or already removed for good, 410 (`isRestoreWindowExpired`) when
    /// its date has passed.
    public func restorePost(id: String) async -> ApiResponse<SocialPost> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/social/posts/\(Self.segment(id))/restore",
            credential: .accessToken
        ))
    }
}

extension ApiError {
    /// Social's answer to restoring a post whose date has passed.
    public var isRestoreWindowExpired: Bool {
        rawCode == "RESTORE_WINDOW_EXPIRED" || statusCode == 410
    }
}
