import Combine
import CoreLocation
import Foundation
import os.log
import ScaleMuleCore
import ScaleMulePhotos
import ScaleMuleSocial
#if os(iOS)
import ScaleMuleLocation
#endif

/// A ready-made model for a photo and video feed of `MediaPost`s: everyone's
/// posts (the app's Social feed), the person's own, or what is nearby
/// (`NearbyFeed`: around where they are, or at one venue).
///
/// - Opens on the first page saved last time (per person, on disk) while
///   the network answers.
/// - Pages on demand; a load replaced by a newer one (another filter) never
///   overwrites it.
/// - Polls for new posts while on screen and offers them as `newItems`, so
///   the page under the person's thumb does not jump.
/// - Likes come from the server (`likedByMe`); a tap shows at once and is
///   undone if the server refuses (409 means it was already liked).
/// - Reported posts and blocked people disappear at once.
///
/// Draw it with `FeedPager`, `RemotePhotoView` and `RemoteVideoView`.
@MainActor
public final class SocialFeedModel: ObservableObject {
    public enum Filter: String, CaseIterable, Sendable {
        /// Everyone's posts: the app's Social feed.
        case everyone = "all"
        /// Around where the person is (iOS).
        case nearby
        /// The person's own posts.
        case mine
    }

    /// One venue's posts (tap a post's place).
    public struct Place: Equatable, Sendable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// A problem to show the person (`localizedDescription` is the text).
    public struct FeedError: LocalizedError, Equatable {
        public let message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    @Published public private(set) var items: [MediaPost] = []
    @Published public private(set) var isLoading = false
    /// The server has answered once (until then an empty list means "still
    /// loading", not "no posts").
    @Published public private(set) var hasLoaded = false
    @Published public private(set) var isLoadingMore = false
    @Published public private(set) var error: Error?
    @Published public private(set) var hasMore = true
    /// Posts newer than the top of the list, waiting for `showNewItems()`.
    @Published public private(set) var newItems: [MediaPost] = []
    /// Changing it loads the new filter.
    @Published public var filter: Filter = .everyone {
        didSet { if oldValue != filter { Task { await loadFeed() } } }
    }
    /// The radius "Nearby" searched (Social widens it until it finds enough).
    @Published public private(set) var nearbyRadiusKm: Double?
    /// A distance the person picked; nil lets Social widen by itself.
    @Published public var nearbyRadiusChoiceKm: Double? {
        didSet { if oldValue != nearbyRadiusChoiceKm && filter == .nearby { Task { await loadFeed() } } }
    }
    /// Showing one venue's posts instead of everything nearby.
    @Published public private(set) var place: Place?
    /// Posts the person likes: what Social said at load (`likedByMe`), then their taps.
    @Published public private(set) var likedIds: Set<String> = []

    public let pageSize: Int
    /// Seconds between looks for new posts while polling.
    public var pollInterval: TimeInterval
    /// Saved first pages go here (default: Caches).
    public var cacheDirectory: URL?
    /// The saved first page's file name: "<savedPageName>-<user id>.json".
    public var savedPageName: String
    /// What each "Nearby" problem says.
    public var nearbyProblemMessage: (NearbyProblem) -> String = SocialFeedModel.defaultNearbyMessage

    private let logger = Logger(subsystem: "com.scalemule.ios", category: "SocialFeedModel")
    private var social: SocialService?
    private var photos: PhotosService?
    private var currentUserId: String?
    private var hiddenPostIds: Set<String> = []
    private var blockedAuthorIds: Set<String> = []
    private var nextPage = 1
    /// The latest load; an earlier one still running (another filter) is dropped.
    private var loadGeneration = 0
    private var pollTask: Task<Void, Never>?
    /// Fixed content (previews, UI tests): nothing is loaded.
    private var isFixed = false
    #if os(iOS)
    private var nearby: NearbyFeed?
    private let location: LocationAccess
    #endif

    #if os(iOS)
    public init(
        pageSize: Int = 20,
        pollInterval: TimeInterval = 15,
        savedPageName: String = "feed",
        cacheDirectory: URL? = nil,
        location: LocationAccess = .shared
    ) {
        self.pageSize = pageSize
        self.pollInterval = pollInterval
        self.savedPageName = savedPageName
        self.cacheDirectory = cacheDirectory
        self.location = location
    }
    #else
    public init(pageSize: Int = 20, pollInterval: TimeInterval = 15, savedPageName: String = "feed", cacheDirectory: URL? = nil) {
        self.pageSize = pageSize
        self.pollInterval = pollInterval
        self.savedPageName = savedPageName
        self.cacheDirectory = cacheDirectory
    }
    #endif

    /// Connect to the signed-in person's services. Shows the saved first
    /// page at once when the list is still empty.
    public func attach(social: SocialService, photos: PhotosService, currentUserId: String?) {
        self.social = social
        self.photos = photos
        self.currentUserId = currentUserId
        #if os(iOS)
        nearby = NearbyFeed(social: social, access: location, pageSize: pageSize)
        #endif
        guard !isFixed else { return }
        if items.isEmpty, filter == .everyone { items = visible(fromServer(savedPage())) }
    }

    /// Show these posts and load nothing (previews, UI tests, sample feeds).
    public func showFixed(_ items: [MediaPost], newItems: [MediaPost] = []) {
        isFixed = true
        self.items = items
        self.newItems = newItems
        hasMore = false
        hasLoaded = true
        isLoading = false
    }

    // MARK: - Saved first page

    private var savedPageURL: URL? {
        guard let currentUserId else { return nil }
        let name = currentUserId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let folder = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return folder.appendingPathComponent("\(savedPageName)-\(name).json")
    }

    /// The first page of everyone's feed as last seen by this person.
    public func savedPage() -> [MediaPost] {
        guard let url = savedPageURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([MediaPost].self, from: data)) ?? []
    }

    private func savePage(_ list: [MediaPost]) {
        guard let url = savedPageURL, let data = try? JSONEncoder().encode(Array(list.prefix(pageSize))) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Loading

    /// The first page of the current filter.
    public func loadFeed() async {
        if isFixed { return }
        loadGeneration += 1
        let mine = loadGeneration
        isLoading = items.isEmpty
        error = nil
        do {
            nextPage = 1
            hasMore = true
            let page = try await fetchNext(generation: mine)
            guard mine == loadGeneration else { return }
            items = visible(fromServer(page))
            newItems = []
            if filter == .everyone { savePage(page) }
        } catch {
            guard mine == loadGeneration else { return }
            logger.error("Feed load failed: \(error.localizedDescription, privacy: .public)")
            self.error = error
            // Never show everyone's posts under "Nearby".
            if filter == .nearby { items = [] }
        }
        isLoading = false
        hasLoaded = true
    }

    public func refresh() async {
        await loadFeed()
    }

    /// The next page, appended (posts already shown are skipped).
    public func loadMore() async {
        guard !isFixed, !isLoadingMore, !isLoading, hasMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let mine = loadGeneration
            let page = try await fetchNext(generation: mine)
            guard mine == loadGeneration else { return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: visible(fromServer(page.filter { !known.contains($0.id) })))
        } catch {
            logger.error("Load more failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Put the waiting new posts at the top.
    public func showNewItems() {
        guard !newItems.isEmpty else { return }
        let known = Set(newItems.map(\.id))
        items = visible(fromServer(newItems)) + items.filter { !known.contains($0.id) }
        newItems = []
    }

    /// Put a post the person just made at the top right away (under
    /// "Nearby", only when it is within the radius shown or at the venue shown).
    public func insertOwnPost(_ post: MediaPost) {
        if filter == .nearby {
            #if os(iOS)
            if let place {
                guard post.placeId == place.id else { return }
            } else {
                guard let here = location.current, let radius = nearbyRadiusKm,
                      let distance = post.distance(from: here), distance <= radius * 1000 else { return }
            }
            #else
            return
            #endif
        }
        items.removeAll { $0.id == post.id }
        newItems.removeAll { $0.id == post.id }
        items.insert(post, at: 0)
    }

    // MARK: - Likes

    public func isLiked(_ post: MediaPost) -> Bool { likedIds.contains(post.id) }

    /// The count to show next to the heart.
    public func likeCount(_ post: MediaPost) -> Int { post.likeCount(liked: isLiked(post)) }

    /// Like or unlike: shown at once, put back if the server refuses
    /// (a 409 means it was already in that state, so it stays).
    public func toggleLike(_ post: MediaPost) async {
        guard let social else { return }
        let wasLiked = likedIds.contains(post.id)
        if wasLiked { likedIds.remove(post.id) } else { likedIds.insert(post.id) }
        let result = wasLiked
            ? await social.unlike(.post, id: post.id)
            : await social.like(.post, id: post.id)
        if case .failure(let apiError) = result, apiError.code != .conflict {
            if wasLiked { likedIds.insert(post.id) } else { likedIds.remove(post.id) }
        }
    }

    // MARK: - Hiding, blocking, deleting

    /// Hide a post the person reported.
    public func hideReported(_ post: MediaPost) {
        hiddenPostIds.insert(post.id)
        items = visible(items)
        newItems = visible(newItems)
    }

    /// Hide everything by these people (the person's block list).
    public func setBlockedAuthors(_ ids: Set<String>) {
        blockedAuthorIds = ids
        items = visible(items)
        newItems = visible(newItems)
    }

    /// Hide the author's posts at once, then `perform` the block (for
    /// example `BlockService.block`); if it fails the block is undone (their
    /// posts show again from the next load) and `error` says why.
    public func block(_ post: MediaPost, perform: () async -> ApiResponse<EmptyResponse>) async {
        let previous = blockedAuthorIds
        setBlockedAuthors(previous.union([post.authorId]))
        if case .failure(let apiError) = await perform() {
            setBlockedAuthors(previous)
            error = FeedError(message: apiError.userFacingMessage)
        }
    }

    /// Delete one of the person's own posts, then its photo. (ScaleMule
    /// Video has no delete yet: a video post's video stays, unlisted.)
    public func deleteOwnPost(_ post: MediaPost) async {
        guard post.isMine, let social else { return }
        switch await social.deletePost(id: post.id) {
        case .success:
            items.removeAll { $0.id == post.id }
            newItems.removeAll { $0.id == post.id }
            if post.isPhoto, let photos { _ = await photos.delete(id: post.mediaId) }
        case .failure(let apiError):
            error = FeedError(message: apiError.userFacingMessage)
        }
    }

    /// Hide posts by blocked people and posts the person reported; take the
    /// server's word on which ones the person liked.
    /// Hide posts the person reported and posts by people they blocked.
    private func visible(_ list: [MediaPost]) -> [MediaPost] {
        list.filter { !hiddenPostIds.contains($0.id) && !blockedAuthorIds.contains($0.authorId) }
    }

    /// Posts just read from Social: their liked state is Social's word.
    /// (Only here: re-filtering posts already shown must never undo a
    /// like tapped since they loaded.)
    private func fromServer(_ list: [MediaPost]) -> [MediaPost] {
        for post in list {
            if post.likedByMe { likedIds.insert(post.id) } else { likedIds.remove(post.id) }
        }
        return list
    }

    // MARK: - New posts

    /// Look for new posts every `pollInterval` seconds until `stopPolling()`.
    public func startPolling() {
        pollTask?.cancel()
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.checkForNewPosts()
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One look for posts newer than those shown (everyone's feed only). An
    /// empty feed shows them at once; otherwise they wait in `newItems`.
    public func checkForNewPosts() async {
        guard !isFixed, let social, filter == .everyone, !isLoading else { return }
        guard case .success(let posts) = await social.feed(page: 1, perPage: pageSize) else { return }
        let known = Set(items.map(\.id)).union(newItems.map(\.id))
        let fresh = posts
            .compactMap { MediaPost(post: $0, currentUserId: currentUserId) }
            .filter { !known.contains($0.id) }
            .filter { !hiddenPostIds.contains($0.id) && !blockedAuthorIds.contains($0.authorId) }
        guard !fresh.isEmpty else { return }
        if items.isEmpty {
            items = fresh
        } else {
            newItems = fresh + newItems
        }
    }

    // MARK: - Nearby

    /// Why "Nearby" shows nothing.
    public enum NearbyProblem: Equatable, Sendable {
        case locationOff
        case locationUnavailable
        case notHere
        case failed(String)
    }

    public nonisolated static func defaultNearbyMessage(_ problem: NearbyProblem) -> String {
        switch problem {
        case .locationOff: return "Turn on location to see photos near you."
        case .locationUnavailable: return "Couldn't find where you are. Try again in a moment."
        case .notHere: return "Nearby shows photos around where you are right now."
        case .failed(let message): return message
        }
    }

    #if os(iOS)
    /// "Nearby" is offered only when location is on (or not asked yet):
    /// location-filtered posts follow where the person really is.
    public var canUseNearby: Bool { location.isOn || location.canAsk }

    public func requestLocationPermission() { location.requestPermission() }

    /// Everything posted at one venue lately.
    public func showPlace(id: String, name: String) {
        location.requestPermission()
        place = Place(id: id, name: name)
        if filter == .nearby { Task { await loadFeed() } } else { filter = .nearby }
    }

    /// Back to everything nearby.
    public func clearPlace() {
        guard place != nil else { return }
        place = nil
        if filter == .nearby { Task { await loadFeed() } }
    }

    private static func problem(_ problem: NearbyFeed.Problem) -> NearbyProblem {
        switch problem {
        case .locationOff: return .locationOff
        case .locationUnavailable: return .locationUnavailable
        case .notHere: return .notHere
        case .failed(let message): return .failed(message)
        }
    }
    #endif

    // MARK: - Fetching

    /// Stops a load that a newer one replaced before it touches the paging state.
    private func stillCurrent(_ generation: Int) throws {
        if generation != loadGeneration { throw CancellationError() }
    }

    private func fetchNext(generation: Int) async throws -> [MediaPost] {
        guard let social else { throw FeedError(message: "Not signed in") }
        let userId = currentUserId
        switch filter {
        case .everyone:
            let result = await social.feed(page: nextPage, perPage: pageSize)
            try stillCurrent(generation)
            return try page(result).compactMap { MediaPost(post: $0, currentUserId: userId) }

        case .mine:
            guard let userId else { throw FeedError(message: "Not signed in") }
            let result = await social.userPosts(userId: userId, page: nextPage, perPage: pageSize)
            try stillCurrent(generation)
            return try page(result).compactMap { MediaPost(post: $0, currentUserId: userId) }

        case .nearby:
            #if os(iOS)
            guard let nearby else { throw FeedError(message: "Not signed in") }
            if nextPage == 1 {
                nearby.fixedRadiusKm = nearbyRadiusChoiceKm
                await nearby.load(place.map { .place(id: $0.id, name: $0.name) } ?? .around)
            } else {
                await nearby.loadMore()
            }
            try stillCurrent(generation)
            nextPage += 1
            nearbyRadiusKm = place == nil ? nearby.radiusKm : nil
            if let problem = nearby.problem {
                hasMore = false
                throw FeedError(message: nearbyProblemMessage(Self.problem(problem)))
            }
            hasMore = nearby.hasMore
            return nearby.posts.compactMap { MediaPost(post: $0.post, currentUserId: userId) }
            #else
            hasMore = false
            throw FeedError(message: nearbyProblemMessage(.locationUnavailable))
            #endif
        }
    }

    /// Unwraps one page and advances the page counter.
    private func page(_ result: ApiResponse<[SocialPost]>) throws -> [SocialPost] {
        switch result {
        case .success(let posts):
            hasMore = !posts.isEmpty && posts.count >= pageSize
            nextPage += 1
            return posts
        case .failure(let apiError):
            throw FeedError(message: apiError.userFacingMessage)
        }
    }
}
