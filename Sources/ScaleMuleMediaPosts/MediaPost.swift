import CoreLocation
import Foundation
import ScaleMuleCore
import ScaleMuleSocial

/// A Social post that shows one photo or one short video: the first of its
/// `mediaIds` is a ScaleMule Photos or Video id, and the post's metadata says
/// which (`MediaPost.Keys`). Where it was is the post's public location (the
/// venue, city or spot its author chose).
///
/// `MediaPostPublisher` writes these posts; any app reading the same keys
/// shows them. Posts written before post locations carried only a place name
/// in metadata (`Keys.place`); they still read.
public struct MediaPost: Identifiable, Equatable, Codable, Sendable {
    /// What a post shows.
    public enum Kind: String, Codable, Sendable {
        case photo
        case video
    }

    /// The metadata keys a media post carries. Never put coordinates in
    /// metadata: Social removes them; the location goes in `SocialPost.location`.
    public enum Keys {
        /// "photo" or "video"; missing means photo.
        public static let kind = "kind"
        /// The author's public name as shown on the post.
        public static let authorName = "author_name"
        /// The location's label, for readers older than post locations.
        public static let place = "place"
        public static let width = "width"
        public static let height = "height"
        public static let caption = "caption"
        /// Seconds, for videos.
        public static let duration = "duration"
    }

    public let id: String
    /// The ScaleMule Photos id (photo) or ScaleMule Video id (video).
    public let mediaId: String
    public let authorId: String
    /// The name to show: the post's author name, else `ownName` for your own
    /// posts and `otherName` for others' (see `init(post:currentUserId:)`).
    public let authorName: String
    public let kind: Kind
    public let width: Int?
    public let height: Int?
    /// What the author wrote with it, if anything.
    public let caption: String?
    /// Seconds, for videos.
    public let duration: Double?
    /// The post's public location, when it has one.
    public let location: SharedLocation?
    /// What to show for where it was: the location's label ("near Oakland"
    /// for an area), else the place name older posts kept in metadata.
    public let place: String?
    /// Likes when the post was loaded (including yours when `likedByMe`).
    public let likes: Int
    /// Whether the signed-in person had liked it when it was loaded.
    public let likedByMe: Bool
    public let createdAt: Date?
    public let isMine: Bool

    /// Read a Social post; nil when it has no media.
    ///
    /// - Parameters:
    ///   - ownName: shown on your own posts that carry no author name.
    ///   - otherName: shown on other people's posts that carry no author name.
    public init?(post: SocialPost, currentUserId: String?, ownName: String = "You", otherName: String = "Someone") {
        guard let mediaId = post.mediaIds?.first, !mediaId.isEmpty else { return nil }
        id = post.id
        self.mediaId = mediaId
        authorId = post.userId
        isMine = post.userId == currentUserId
        authorName = post.metadataString(Keys.authorName).flatMap { $0.isEmpty ? nil : $0 }
            ?? (isMine ? ownName : otherName)
        location = post.location
        if let location = post.location {
            place = location.label.map { location.precision == .area ? "near \($0)" : $0 }
                ?? post.metadataString(Keys.place)
        } else {
            place = post.metadataString(Keys.place)
        }
        width = post.metadataDouble(Keys.width).map { Int($0) }
        height = post.metadataDouble(Keys.height).map { Int($0) }
        createdAt = post.createdDate
        caption = post.metadataString(Keys.caption).flatMap { $0.isEmpty ? nil : $0 }
        likes = post.likesCount
        likedByMe = post.likedByMe ?? false
        kind = post.metadataString(Keys.kind).flatMap(Kind.init(rawValue:)) ?? .photo
        duration = post.metadataDouble(Keys.duration)
    }

    /// Posts are the same post when their ids match (a feed replaces a stale
    /// copy by id).
    public static func == (lhs: MediaPost, rhs: MediaPost) -> Bool { lhs.id == rhs.id }

    public var isVideo: Bool { kind == .video }
    public var isPhoto: Bool { kind == .photo }

    /// Clearly wider than tall (more than 1.05 : 1).
    public var isLandscape: Bool {
        guard let width, let height, height > 0 else { return false }
        return Double(width) / Double(height) > 1.05
    }

    /// The venue's id when shared at a venue: everything posted there is one tap away.
    public var placeId: String? {
        location?.precision == .place ? location?.placeId : nil
    }

    /// The post's public point.
    public var coordinate: CLLocationCoordinate2D? {
        location.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// How exact `coordinate` is.
    public var precision: LocationPrecision? { location?.precision }

    /// The like count to show while the heart shows `liked` (the person may
    /// have tapped it since the post was loaded).
    public func likeCount(liked: Bool) -> Int {
        likes + (liked && !likedByMe ? 1 : 0) - (!liked && likedByMe ? 1 : 0)
    }

    /// Metres from `location` to the post's public point.
    public func distance(from location: CLLocation) -> CLLocationDistance? {
        guard let coordinate else { return nil }
        return location.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    /// "Under 1 km away", "2.4 km away", "35 km away". Only for venues and
    /// chosen spots: a city's centre is not where the post was.
    public func distanceString(from location: CLLocation) -> String? {
        guard precision == .place || precision == .exact, let distance = distance(from: location) else { return nil }
        if distance < 1000 { return "Under 1 km away" }
        if distance < 10000 { return String(format: "%.1f km away", distance / 1000) }
        return String(format: "%.0f km away", distance / 1000)
    }

    /// "Just now", "5m ago", "3h ago", "2d ago", then the date.
    public func timeAgo(now: Date = Date()) -> String {
        guard let createdAt else { return "" }
        let interval = now.timeIntervalSince(createdAt)
        if interval < 60 { return "Just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        if interval < 604800 { return "\(Int(interval / 86400))d ago" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter.string(from: createdAt)
    }

    // MARK: Saved copies

    // A feed saves its first page so the app opens on posts before the
    // network answers. Older saved copies (Firehosy's FeedItem: photoId,
    // likesCount, likedAtLoad, latitude/longitude/precision/placeId) still read.
    private enum CodingKeys: String, CodingKey {
        case id, mediaId, authorId, authorName, kind, width, height, caption, duration
        case location, place, likes, likedByMe, createdAt, isMine
        case photoId, likesCount, likedAtLoad, latitude, longitude, precision, placeId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        if let mediaId = try c.decodeIfPresent(String.self, forKey: .mediaId) {
            self.mediaId = mediaId
        } else {
            mediaId = try c.decode(String.self, forKey: .photoId)
        }
        authorId = try c.decode(String.self, forKey: .authorId)
        authorName = try c.decode(String.self, forKey: .authorName)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .photo
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        caption = try c.decodeIfPresent(String.self, forKey: .caption)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        place = try c.decodeIfPresent(String.self, forKey: .place)
        if let location = try c.decodeIfPresent(SharedLocation.self, forKey: .location) {
            self.location = location
        } else if let latitude = try c.decodeIfPresent(Double.self, forKey: .latitude),
                  let longitude = try c.decodeIfPresent(Double.self, forKey: .longitude) {
            location = SharedLocation(
                precision: try c.decodeIfPresent(LocationPrecision.self, forKey: .precision) ?? .city,
                latitude: latitude,
                longitude: longitude,
                placeId: try c.decodeIfPresent(String.self, forKey: .placeId)
            )
        } else {
            location = nil
        }
        likes = try c.decodeIfPresent(Int.self, forKey: .likes) ?? c.decodeIfPresent(Int.self, forKey: .likesCount) ?? 0
        likedByMe = try c.decodeIfPresent(Bool.self, forKey: .likedByMe) ?? c.decodeIfPresent(Bool.self, forKey: .likedAtLoad) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        isMine = try c.decode(Bool.self, forKey: .isMine)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(mediaId, forKey: .mediaId)
        try c.encode(authorId, forKey: .authorId)
        try c.encode(authorName, forKey: .authorName)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(width, forKey: .width)
        try c.encodeIfPresent(height, forKey: .height)
        try c.encodeIfPresent(caption, forKey: .caption)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encodeIfPresent(place, forKey: .place)
        try c.encode(likes, forKey: .likes)
        try c.encode(likedByMe, forKey: .likedByMe)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encode(isMine, forKey: .isMine)
    }
}
