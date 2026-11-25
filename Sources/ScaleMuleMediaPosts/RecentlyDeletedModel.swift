import Combine
import Foundation
import ScaleMuleCore
import ScaleMuleSocial

/// The signed-in person's deleted posts that can still be restored, for a
/// "Recently deleted" screen: most recently deleted first, each with the
/// days it has left, pages on demand.
///
/// Restore takes the post out of the list at once and puts it back where it
/// was if the server refuses; `onRestored` hands the post to the feed
/// (`SocialFeedModel.showRestored`). Draw each row with `MediaThumbnailView`
/// (the author can still load a deleted post's photo or video poster).
///
/// Posts without a photo or video are not listed (see `MediaPost`).
@MainActor
public final class RecentlyDeletedModel: ObservableObject {
    /// One deleted post.
    public struct Item: Identifiable, Equatable, Sendable {
        public let post: MediaPost
        public let deletedAt: Date?
        /// After this the post is removed for good, with its photo or video.
        public let restorableUntil: Date?

        public var id: String { post.id }

        public init(post: MediaPost, deletedAt: Date? = nil, restorableUntil: Date? = nil) {
            self.post = post
            self.deletedAt = deletedAt
            self.restorableUntil = restorableUntil
        }

        /// Days until it is removed for good; a part of a day counts as a
        /// day, 0 once the date has passed.
        public func daysLeft(now: Date = Date()) -> Int {
            guard let restorableUntil else { return 0 }
            let seconds = restorableUntil.timeIntervalSince(now)
            return seconds > 0 ? Int((seconds / 86_400).rounded(.up)) : 0
        }

        public static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.post.id == rhs.post.id && lhs.deletedAt == rhs.deletedAt && lhs.restorableUntil == rhs.restorableUntil
        }
    }

    @Published public private(set) var items: [Item] = []
    @Published public private(set) var isLoading = false
    /// The server has answered once (an empty list then means "nothing deleted").
    @Published public private(set) var hasLoaded = false
    @Published public private(set) var hasMore = false
    /// Posts whose restore is on its way to the server.
    @Published public private(set) var restoring: Set<String> = []
    /// Who may restore in this app, as Social said with the list. Offer
    /// Restore only for `.author`.
    @Published public private(set) var restorableBy: PostRestorer = .author
    /// What went wrong last, in words for the person; nil when nothing did.
    @Published public var errorMessage: String?

    public let pageSize: Int
    /// A post was restored: show it in the feed again.
    public var onRestored: ((MediaPost) -> Void)?

    private var social: SocialService?
    private var currentUserId: String?
    private var nextPage = 1
    /// The latest first-page load; an older one still running is dropped.
    private var loadGeneration = 0
    /// Counts sign-outs: an answer for the last person is dropped.
    private var session = 0
    /// Posts restored here, with the latest load begun by then: a list read
    /// before the restore (and arriving after it) still names the post.
    private var restoredDuring: [String: Int] = [:]

    public init(pageSize: Int = 30) {
        self.pageSize = pageSize
    }

    /// Connect to the signed-in person's Social. Another person signing in
    /// starts from nothing.
    public func attach(social: SocialService, currentUserId: String?) {
        if currentUserId != self.currentUserId { reset() }
        self.social = social
        self.currentUserId = currentUserId
    }

    /// Signed out: nothing of the last person stays.
    public func reset() {
        loadGeneration += 1
        session += 1
        items = []
        restoring = []
        restoredDuring = [:]
        hasLoaded = false
        hasMore = false
        isLoading = false
        restorableBy = .author
        errorMessage = nil
        nextPage = 1
    }

    /// The person can restore these posts themselves.
    public var canRestore: Bool { restorableBy == .author }

    /// The first page. When it fails the list already shown stays and
    /// `errorMessage` says why.
    public func load() async {
        guard let social else { return }
        loadGeneration += 1
        let mine = loadGeneration
        isLoading = true
        let result = await social.deletedPosts(page: 1, perPage: pageSize)
        guard mine == loadGeneration else { return }
        isLoading = false
        hasLoaded = true
        switch result {
        case .success(let page):
            restorableBy = page.restorableBy
            items = read(page.posts).filter { stillDeleted($0.id, loadBegun: mine) }
            nextPage = 2
            hasMore = page.posts.count >= pageSize
            errorMessage = nil
        case .failure(let error):
            errorMessage = error.userFacingMessage
        }
    }

    public func loadMore() async {
        guard let social, hasMore, !isLoading else { return }
        let mine = loadGeneration
        isLoading = true
        let result = await social.deletedPosts(page: nextPage, perPage: pageSize)
        guard mine == loadGeneration else { return }
        isLoading = false
        guard case .success(let page) = result else { return }
        let known = Set(items.map(\.id))
        items.append(contentsOf: read(page.posts).filter { !known.contains($0.id) && stillDeleted($0.id, loadBegun: mine) })
        nextPage += 1
        hasMore = page.posts.count >= pageSize
    }

    /// Bring a post back. It leaves the list at once; if the server refuses
    /// it returns to its place and `errorMessage` says why. A post that can
    /// no longer be restored (its date passed, or it is already gone) stays
    /// out of the list. Returns the restored post.
    @discardableResult
    public func restore(_ item: Item) async -> MediaPost? {
        guard let social, canRestore, !restoring.contains(item.id),
              let index = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        let asked = session
        items.remove(at: index)
        restoring.insert(item.id)
        errorMessage = nil
        let result = await social.restorePost(id: item.id)
        // Signed out meanwhile: the next person's list is not touched.
        guard asked == session else { return nil }
        restoring.remove(item.id)
        switch result {
        case .success(let post):
            restoredDuring[item.id] = loadGeneration
            items.removeAll { $0.id == item.id }
            let restored = MediaPost(post: post, currentUserId: currentUserId) ?? item.post
            onRestored?(restored)
            return restored
        case .failure(let error):
            if error.isRestoreWindowExpired || error.code == .notFound {
                errorMessage = "This post was deleted too long ago and can't be restored any more."
            } else {
                if !items.contains(where: { $0.id == item.id }) {
                    items.insert(item, at: min(index, items.count))
                }
                errorMessage = error.userFacingMessage
            }
            return nil
        }
    }

    /// Whether a post named by a list really is still deleted: not while its
    /// restore is on its way, and not when the list was asked for before the
    /// restore finished (Social read it while the post was still deleted).
    private func stillDeleted(_ id: String, loadBegun generation: Int) -> Bool {
        if restoring.contains(id) { return false }
        if let restored = restoredDuring[id], restored >= generation { return false }
        return true
    }

    private func read(_ posts: [DeletedPost]) -> [Item] {
        posts.compactMap { deleted in
            MediaPost(post: deleted.post, currentUserId: currentUserId).map {
                Item(post: $0, deletedAt: deleted.deletedAt, restorableUntil: deleted.restorableUntil)
            }
        }
    }
}
