import Foundation
import ScaleMuleCore

/// How exact a post's location is. Social snaps every point to its
/// precision's grid, whatever the app sends (platform contract:
/// scalemule-repos `docs/LOCATION-PRIVACY.md`).
public enum LocationPrecision: String, Sendable, Codable, CaseIterable, Hashable {
    /// A public venue (gallery, concert hall, park): the venue's own point.
    case place
    /// The centre of the city, or of the nearest city. About 2 km.
    case city
    /// A coarse area, about 11 km.
    case area
    /// The spot itself, only when the person chooses it.
    case exact
}

/// The public location a post shares, and how readers get it back. Never the
/// person's GPS fix: build it with `ScaleMuleLocation`'s `PlaceResolver`.
public struct SharedLocation: Sendable, Codable, Equatable, Hashable {
    public var precision: LocationPrecision
    public var latitude: Double
    public var longitude: Double
    /// What readers see: "SFMOMA", "Oakland".
    public var name: String?
    public var locality: String?
    public var region: String?
    /// ISO 3166-1 alpha-2.
    public var countryCode: String?
    /// The venue's map id; posts at one venue share it (`place` only).
    public var placeId: String?

    public init(
        precision: LocationPrecision,
        latitude: Double,
        longitude: Double,
        name: String? = nil,
        locality: String? = nil,
        region: String? = nil,
        countryCode: String? = nil,
        placeId: String? = nil
    ) {
        self.precision = precision
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
        self.locality = locality
        self.region = region
        self.countryCode = countryCode
        self.placeId = placeId
    }

    /// A label for the post: the venue or city name.
    public var label: String? { name ?? locality }

    private enum CodingKeys: String, CodingKey {
        case precision, latitude, longitude, name, locality, region
        case countryCode = "country_code"
        case placeId = "place_id"
    }

    var body: [String: Any] {
        var body: [String: Any] = [
            "precision": precision.rawValue,
            "latitude": latitude,
            "longitude": longitude,
        ]
        if let name { body["name"] = name }
        if let locality { body["locality"] = locality }
        if let region { body["region"] = region }
        if let countryCode { body["country_code"] = countryCode }
        if let placeId { body["place_id"] = placeId }
        return body
    }
}

/// A post found by location, with its distance from where the search was.
public struct NearbyPost: Sendable, Decodable, Identifiable, Equatable {
    public let post: SocialPost
    /// Kilometres from the search point to the post's public point.
    public let distanceKm: Double
    public var id: String { post.id }

    public init(post: SocialPost, distanceKm: Double) {
        self.post = post
        self.distanceKm = distanceKm
    }

    private enum CodingKeys: String, CodingKey {
        case distanceKm = "distance_km"
    }

    public init(from decoder: Decoder) throws {
        post = try SocialPost(from: decoder)
        distanceKm = try decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent(Double.self, forKey: .distanceKm) ?? 0
    }
}

/// One page of posts by location.
public struct NearbyPage: Sendable, Decodable, Equatable {
    public let posts: [NearbyPost]
    /// The radius searched, after widening; send it back with `nextCursor`.
    public let radiusKm: Double
    public let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case posts
        case radiusKm = "radius_km"
        case nextCursor = "next_cursor"
    }
}

/// An app's location settings (set by its team).
public struct LocationSettings: Sendable, Decodable, Equatable {
    public let allowedPrecisions: [LocationPrecision]
    /// Searches show what is around where the viewer is.
    public let presenceRequired: Bool
    /// What a new post starts with.
    public let defaultPrecision: LocationPrecision

    public init(allowedPrecisions: [LocationPrecision], presenceRequired: Bool, defaultPrecision: LocationPrecision) {
        self.allowedPrecisions = allowedPrecisions
        self.presenceRequired = presenceRequired
        self.defaultPrecision = defaultPrecision
    }

    /// What Social uses for an app that set nothing.
    public static let standard = LocationSettings(
        allowedPrecisions: LocationPrecision.allCases,
        presenceRequired: true,
        defaultPrecision: .city
    )

    private enum CodingKeys: String, CodingKey {
        case allowedPrecisions = "allowed_precisions"
        case presenceRequired = "presence_required"
        case defaultPrecision = "default_precision"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([String].self, forKey: .allowedPrecisions) ?? []
        allowedPrecisions = raw.compactMap(LocationPrecision.init(rawValue:))
        presenceRequired = try c.decodeIfPresent(Bool.self, forKey: .presenceRequired) ?? true
        defaultPrecision = (try? c.decode(LocationPrecision.self, forKey: .defaultPrecision)) ?? .city
    }
}

/// Whether the signed-in person may look at places other than where they are.
public struct ExplorerStatus: Sendable, Decodable, Equatable {
    public let explorer: Bool
    public let expiresAt: String?

    private enum CodingKeys: String, CodingKey {
        case explorer
        case expiresAt = "expires_at"
    }
}

public extension ApiError {
    /// The search was for a place the person cannot be yet. Offer "Explore
    /// anywhere", or search where they are.
    var isLocationNotHere: Bool { rawCode == "LOCATION_NOT_HERE" }
    /// The app does not share that precision.
    var isLocationPrecisionNotAllowed: Bool { rawCode == "LOCATION_PRECISION_NOT_ALLOWED" }
}

public extension SocialService {
    /// Public posts around a point, newest first. Without `radiusKm` the
    /// search widens 5 → 25 → 160 km until it finds a page worth showing;
    /// pass the returned `radiusKm` with `cursor` for the next page.
    ///
    /// For apps that ask for presence (the default), `latitude`/`longitude`
    /// must be where the person is now: a jump nobody could make fails with
    /// `isLocationNotHere`.
    func postsNear(
        latitude: Double,
        longitude: Double,
        radiusKm: Double? = nil,
        windowHours: Int? = nil,
        limit: Int = 30,
        cursor: String? = nil
    ) async -> ApiResponse<NearbyPage> {
        // POST: the person's position goes in the body, never in a URL that
        // load balancers log.
        var body: [String: Any] = [
            "latitude": latitude,
            "longitude": longitude,
            "limit": min(max(limit, 1), 100),
        ]
        if let radiusKm { body["radius_km"] = radiusKm }
        if let windowHours { body["window_hours"] = windowHours }
        if let cursor { body["cursor"] = cursor }
        return await client.request(RequestOptions(
            method: .post,
            path: "/v1/social/posts/near",
            body: body,
            credential: .accessToken
        ))
    }

    /// A venue's public posts, newest first (default the last 24 hours):
    /// everyone at the gallery or concert now. `latitude`/`longitude` are where
    /// the person is.
    func postsAtPlace(
        placeId: String,
        latitude: Double,
        longitude: Double,
        windowHours: Int? = nil,
        limit: Int = 30,
        cursor: String? = nil
    ) async -> ApiResponse<NearbyPage> {
        var body: [String: Any] = [
            "place_id": placeId,
            "latitude": latitude,
            "longitude": longitude,
            "limit": min(max(limit, 1), 100),
        ]
        if let windowHours { body["window_hours"] = windowHours }
        if let cursor { body["cursor"] = cursor }
        return await client.request(RequestOptions(
            method: .post,
            path: "/v1/social/posts/at-place",
            body: body,
            credential: .accessToken
        ))
    }

    /// The app's allowed precisions and presence rule.
    func locationSettings() async -> ApiResponse<LocationSettings> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/social/location/settings",
            credential: .accessToken
        ))
    }

    /// Whether the signed-in person has "Explore anywhere". Only the app's
    /// server (after a purchase) or team grants it.
    func explorerStatus() async -> ApiResponse<ExplorerStatus> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/social/location/explorer",
            credential: .accessToken
        ))
    }
}
