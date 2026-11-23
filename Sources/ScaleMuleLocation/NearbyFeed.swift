#if os(iOS)
import CoreLocation
import Foundation
import ScaleMuleCore
import ScaleMuleSocial

/// Posts around where the person is, or at one venue, newest first: a
/// ready-made model for an app's "Nearby" tab. It searches only from a real,
/// fresh fix (`LocationAccess`), so people see where they are, not anywhere
/// they type in; Social refuses a jump nobody could make (`.notHere`), which an
/// app can answer with "Explore anywhere".
@MainActor
public final class NearbyFeed: ObservableObject {
    public enum Scope: Equatable, Sendable {
        /// Around the person; the search widens until it finds enough.
        case around
        /// One venue's posts (`SharedLocation.placeId`).
        case place(id: String, name: String?)
    }

    public enum Problem: Equatable, Sendable {
        /// Location is off for the app: show the unfiltered feed, offer to turn it on.
        case locationOff
        /// No real fix arrived (or it was simulated).
        case locationUnavailable
        /// Social refused: the person cannot be there yet.
        case notHere
        case failed(String)
    }

    @Published public private(set) var posts: [NearbyPost] = []
    @Published public private(set) var scope: Scope = .around
    /// The radius the last search used (after widening).
    @Published public private(set) var radiusKm: Double?
    @Published public private(set) var isLoading = false
    @Published public private(set) var problem: Problem?
    @Published public private(set) var hasMore = false

    /// A distance the person picked, in km (at most 160 unless they may
    /// explore anywhere); nil lets Social widen 5 → 25 → 160 km by itself.
    public var fixedRadiusKm: Double?
    /// Distances to offer, in km: round miles where people use miles
    /// (3, 15, 50, 100 mi), else 5, 25, 80, 160 km. 160 km is the most anyone
    /// searches around where they are.
    public static func radiusChoicesKm(locale: Locale = .current) -> [Double] {
        usesMiles(locale) ? [3, 15, 50].map { $0 * 1.609_344 } + [160] : [5, 25, 80, 160]
    }

    /// How far back "around" looks (Social's default is 30 days).
    public var windowHours: Int?
    /// How far back a venue looks (Social's default is 24 hours).
    public var placeWindowHours: Int?
    public var pageSize: Int

    private let social: SocialService
    private let access: LocationAccess
    private var origin: CLLocation?
    private var cursor: String?
    private var generation = 0

    public init(social: SocialService, access: LocationAccess = .shared, pageSize: Int = 30) {
        self.social = social
        self.access = access
        self.pageSize = pageSize
    }

    /// The first page, from where the person is now.
    public func load(_ scope: Scope = .around) async {
        self.scope = scope
        generation += 1
        let mine = generation
        guard access.isOn else {
            reset(.locationOff)
            return
        }
        isLoading = true
        let here = await access.freshLocation()
        guard mine == generation else { return }
        guard let here else {
            isLoading = false
            reset(.locationUnavailable)
            return
        }
        origin = here
        cursor = nil
        await fetch(first: true, generation: mine)
    }

    public func loadMore() async {
        guard hasMore, !isLoading, origin != nil else { return }
        await fetch(first: false, generation: generation)
    }

    /// Show a post the person just made at the top, when it belongs here.
    public func insert(_ post: SocialPost) {
        guard !posts.contains(where: { $0.id == post.id }), let location = post.location, let origin else { return }
        switch scope {
        case .place(let id, _): guard location.placeId == id else { return }
        case .around: break
        }
        let distance = CLLocation(latitude: location.latitude, longitude: location.longitude).distance(from: origin) / 1_000
        if case .around = scope, let radiusKm, distance > radiusKm { return }
        posts.insert(NearbyPost(post: post, distanceKm: (distance * 10).rounded() / 10), at: 0)
    }

    /// "Within 3 mi" or "Within 5 km", in the units of the person's region.
    public static func radiusLabel(_ km: Double, locale: Locale = .current) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium
        formatter.numberFormatter.maximumFractionDigits = 0
        var value = usesMiles(locale) ? km / 1.609_344 : km
        if value > 20 { value = (value / 5).rounded() * 5 } else { value = value.rounded() }
        let unit: UnitLength = usesMiles(locale) ? .miles : .kilometers
        return "Within " + formatter.string(from: Measurement(value: max(value, 1), unit: unit))
    }

    static func usesMiles(_ locale: Locale) -> Bool {
        if #available(iOS 16.0, *) {
            return locale.measurementSystem == .us || locale.measurementSystem == .uk
        }
        return !locale.usesMetricSystem
    }

    public func remove(postId: String) {
        posts.removeAll { $0.id == postId }
    }

    private func reset(_ problem: Problem) {
        isLoading = false
        posts = []
        radiusKm = nil
        hasMore = false
        cursor = nil
        self.problem = problem
    }

    private func fetch(first: Bool, generation mine: Int) async {
        guard let origin else { return }
        isLoading = true
        let result: ApiResponse<NearbyPage>
        switch scope {
        case .around:
            result = await social.postsNear(
                latitude: origin.coordinate.latitude,
                longitude: origin.coordinate.longitude,
                radiusKm: first ? fixedRadiusKm : radiusKm,
                windowHours: windowHours,
                limit: pageSize,
                cursor: first ? nil : cursor
            )
        case .place(let id, _):
            result = await social.postsAtPlace(
                placeId: id,
                latitude: origin.coordinate.latitude,
                longitude: origin.coordinate.longitude,
                windowHours: placeWindowHours,
                limit: pageSize,
                cursor: first ? nil : cursor
            )
        }
        guard mine == generation else { return }
        isLoading = false
        switch result {
        case .success(let page):
            if first {
                posts = page.posts
            } else {
                let known = Set(posts.map(\.id))
                posts += page.posts.filter { !known.contains($0.id) }
            }
            if case .around = scope { radiusKm = page.radiusKm }
            cursor = page.nextCursor
            hasMore = page.nextCursor != nil
            problem = nil
        case .failure(let error):
            if first { reset(error.isLocationNotHere ? .notHere : .failed(error.userFacingMessage)) }
            else { problem = error.isLocationNotHere ? .notHere : .failed(error.userFacingMessage) }
        }
    }
}
#endif
