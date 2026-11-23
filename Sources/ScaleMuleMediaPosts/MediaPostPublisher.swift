import Foundation
import ScaleMuleCore
import ScaleMuleSocial
#if canImport(UIKit)
import ScaleMuleMediaQueue
#endif

/// What an app keeps with a post while `MediaUploadQueue` uploads it
/// (`MediaUploadQueue.post(photo:attributes:)`): the caption and the public
/// location the person chose. Where the photo was really taken goes into the
/// uploaded file only (the queue's `capture`), for ScaleMule to keep privately.
public enum MediaPostAttributes {
    public static let caption = "caption"
    /// The chosen `SharedLocation`, as JSON.
    public static let location = "location"

    public static func make(caption: String, location: SharedLocation?) -> [String: String] {
        var attributes: [String: String] = [:]
        if !caption.isEmpty { attributes[Self.caption] = caption }
        if let location, let data = try? JSONEncoder().encode(location) {
            attributes[Self.location] = String(decoding: data, as: UTF8.self)
        }
        return attributes
    }

    public static func caption(_ attributes: [String: String]) -> String {
        attributes[caption] ?? ""
    }

    /// The chosen location. Attributes without one (or with loose
    /// coordinates, as some older apps queued) give nil: the post goes out
    /// without a location rather than with coordinates.
    public static func location(_ attributes: [String: String]) -> SharedLocation? {
        guard let text = attributes[location] else { return nil }
        return try? JSONDecoder().decode(SharedLocation.self, from: Data(text.utf8))
    }
}

/// Publishes a `MediaPost`: a Social post pointing at an uploaded photo or
/// video, with the metadata every media-post reader understands
/// (`MediaPost.Keys`). It never puts coordinates in metadata: the location
/// goes in the post's `location` (Social snaps it to its precision), and its
/// label also in `place` for readers older than post locations.
public struct MediaPostPublisher: Sendable {
    public let social: SocialService
    /// Tags on every post (for example the app's feed name).
    public var tags: [String]
    public var visibility: PostVisibility
    /// The post's text when it has neither caption nor location (Social
    /// requires some).
    public var defaultContent: String

    public init(social: SocialService, tags: [String] = [], visibility: PostVisibility = .public, defaultContent: String = "Right now") {
        self.social = social
        self.tags = tags
        self.visibility = visibility
        self.defaultContent = defaultContent
    }

    /// The name to show on someone's posts: their first name, else their
    /// username, else "" (readers then show `MediaPost`'s fallback).
    public static func authorName(for user: AuthUser) -> String {
        if let first = user.fullName?.split(separator: " ").first, !first.isEmpty { return String(first) }
        if let username = user.username, !username.isEmpty { return username }
        return ""
    }

    /// The metadata a post gets (also what tests and other platforms check).
    public static func metadata(
        kind: MediaPost.Kind,
        width: Int,
        height: Int,
        duration: Double?,
        caption: String,
        location: SharedLocation?,
        authorName: String
    ) -> [String: Any] {
        var metadata: [String: Any] = [
            MediaPost.Keys.kind: kind.rawValue,
            MediaPost.Keys.authorName: authorName,
            MediaPost.Keys.width: width,
            MediaPost.Keys.height: height,
        ]
        if let place = location?.label { metadata[MediaPost.Keys.place] = place }
        if let duration { metadata[MediaPost.Keys.duration] = (duration * 10).rounded() / 10 }
        if !caption.isEmpty { metadata[MediaPost.Keys.caption] = caption }
        return metadata
    }

    /// Publish a post for media already uploaded. Safe to try again with the
    /// same media: nothing is uploaded here.
    public func publish(
        mediaId: String,
        kind: MediaPost.Kind,
        width: Int,
        height: Int,
        duration: Double? = nil,
        caption: String,
        location: SharedLocation?,
        authorName: String
    ) async -> ApiResponse<MediaPost> {
        let result = await social.createPost(
            content: caption.isEmpty ? (location?.label ?? defaultContent) : caption,
            mediaIds: [mediaId],
            visibility: visibility,
            tags: tags.isEmpty ? nil : tags,
            metadata: Self.metadata(
                kind: kind, width: width, height: height, duration: duration,
                caption: caption, location: location, authorName: authorName
            ),
            location: location
        )
        switch result {
        case .success(let post):
            guard let mediaPost = MediaPost(post: post, currentUserId: post.userId) else {
                return .failure(ApiError(code: .invalidFormat, message: "The post was saved without its photo."))
            }
            return .success(mediaPost)
        case .failure(let error):
            return .failure(error)
        }
    }

    #if canImport(UIKit)
    /// Publish the post for a finished `MediaUploadQueue` upload: caption and
    /// location from its attributes (`MediaPostAttributes`).
    public func publish(_ upload: MediaUpload, authorName: String) async -> ApiResponse<MediaPost> {
        await publish(
            mediaId: upload.mediaId,
            kind: upload.kind == .video ? .video : .photo,
            width: upload.width,
            height: upload.height,
            duration: upload.duration,
            caption: MediaPostAttributes.caption(upload.attributes),
            location: MediaPostAttributes.location(upload.attributes),
            authorName: authorName
        )
    }
    #endif
}
