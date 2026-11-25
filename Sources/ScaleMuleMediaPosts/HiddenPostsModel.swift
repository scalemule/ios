import Combine
import Foundation
import ScaleMuleCore
import ScaleMuleSocial
import ScaleMuleVideos

/// The signed-in person's hidden posts, for a "Hidden posts" screen: most
/// recently hidden first, pages on demand. A hidden post is gone for everyone
/// and is kept for as long as it stays hidden; this list is the only place
/// its author sees it.
///
/// Unhide and Delete both take the post out of the list at once and put it
/// back where it was if the server refuses. `onUnhidden` hands the post to
/// the feed (`SocialFeedModel.showRestored`). Draw each row with
/// `MediaThumbnailView` (the author can still load a hidden post's photo or
/// video poster).
///
/// Posts without a photo or video are not listed (see `MediaPost`).
@MainActor
public final class HiddenPostsModel: ObservableObject {
    /// One hidden post.
    public struct Item: Identifiable, Equatable, Sendable {
        public let post: MediaPost
        public let hiddenAt: Date?

        public var id: String { post.id }

        public init(post: MediaPost, hiddenAt: Date? = nil) {
            self.post = post
            self.hiddenAt = hiddenAt
        }

        public static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.post.id == rhs.post.id && lhs.hiddenAt == rhs.hiddenAt
        }
    }

    @Published public private(set) var items: [Item] = []
    @Published public private(set) var isLoading = false
    /// The server has answered once (an empty list then means "nothing hidden").
    @Published public private(set) var hasLoaded = false
    @Published public private(set) var hasMore = false
    /// Posts whose unhide or delete is on its way to the server.
    @Published public private(set) var working: Set<String> = []
    /// What went wrong last, in words for the person; nil when nothing did.
    @Published public var errorMessage: String?

    public let pageSize: Int
    /// A post is showing again: put it back in the feed.
    public var onUnhidden: ((MediaPost) -> Void)?

    private var social: SocialService?
    private var currentUserId: String?
    private var nextPage = 1
    /// The latest first-page load; an older one still running is dropped.
    private var loadGeneration = 0
    /// Counts sign-outs: an answer for the last person is dropped.
    private var session = 0
    /// Posts that left the list here (shown again or deleted), with the
    /// latest load begun by then: a list read before that (and arriving
    /// after it) still names the post.
    private var leftDuring: [String: Int] = [:]

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
        working = []
        leftDuring = [:]
        hasLoaded = false
        hasMore = false
        isLoading = false
        errorMessage = nil
        nextPage = 1
    }

    /// The first page. When it fails the list already shown stays and
    /// `errorMessage` says why.
    public func load() async {
        guard let social else { return }
        loadGeneration += 1
        let mine = loadGeneration
        isLoading = true
        let result = await social.hiddenPosts(page: 1, perPage: pageSize)
        guard mine == loadGeneration else { return }
        isLoading = false
        hasLoaded = true
        switch result {
        case .success(let page):
            items = read(page.posts).filter { stillHidden($0.id, loadBegun: mine) }
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
        let result = await social.hiddenPosts(page: nextPage, perPage: pageSize)
        guard mine == loadGeneration else { return }
        isLoading = false
        guard case .success(let page) = result else { return }
        let known = Set(items.map(\.id))
        items.append(contentsOf: read(page.posts).filter { !known.contains($0.id) && stillHidden($0.id, loadBegun: mine) })
        nextPage += 1
        hasMore = page.posts.count >= pageSize
    }

    /// Show a post again. It leaves the list at once; if the server refuses
    /// it returns to its place and `errorMessage` says why. A post that is
    /// no longer there to show (deleted meanwhile, or taken down) stays out
    /// of the list. Returns the post as it is now.
    @discardableResult
    public func unhide(_ item: Item) async -> MediaPost? {
        guard let social, let index = begin(item) else { return nil }
        let asked = session
        let result = await social.unhidePost(id: item.id)
        // Signed out meanwhile: the next person's list is not touched.
        guard asked == session else { return nil }
        working.remove(item.id)
        switch result {
        case .success(let post):
            left(item.id)
            let shown = MediaPost(post: post, currentUserId: currentUserId) ?? item.post
            onUnhidden?(shown)
            return shown
        case .failure(let error):
            if error.code == .notFound {
                left(item.id)
                errorMessage = "This post isn't among your hidden posts any more."
            } else if error.code == .forbidden {
                // Taken down while it was hidden: Social's sentence says so.
                left(item.id)
                errorMessage = error.userFacingMessage
            } else {
                putBack(item, at: index)
                errorMessage = error.userFacingMessage
            }
            return nil
        }
    }

    /// Delete a hidden post. It leaves the list at once; if the server
    /// refuses it returns to its place and `errorMessage` says why. Returns
    /// Social's answer: where `canBeRestoredByAuthor()` is false the post is
    /// gone for the person (say so before asking; do not promise a way back).
    /// Only the post is deleted here, never its photo or video (see
    /// `SocialFeedModel.deleteOwnPost`).
    @discardableResult
    public func delete(_ item: Item) async -> PostDeletion? {
        guard let social, let index = begin(item) else { return nil }
        let asked = session
        let result = await social.deletePost(id: item.id)
        guard asked == session else { return nil }
        working.remove(item.id)
        switch result {
        case .success(let deletion):
            left(item.id)
            if item.post.isVideo { VideosService.forgetLocalCopies(of: item.post.mediaId) }
            return deletion
        case .failure(let error):
            if error.code == .notFound {
                // Already gone: nothing to put back.
                left(item.id)
                errorMessage = "This post isn't among your hidden posts any more."
            } else {
                putBack(item, at: index)
                errorMessage = error.userFacingMessage
            }
            return nil
        }
    }

    /// Take `item` out of the list for a change on its way; its place, or
    /// nil when it is not listed or already being worked on.
    private func begin(_ item: Item) -> Int? {
        guard !working.contains(item.id), let index = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        items.remove(at: index)
        working.insert(item.id)
        errorMessage = nil
        return index
    }

    private func left(_ id: String) {
        leftDuring[id] = loadGeneration
        items.removeAll { $0.id == id }
    }

    private func putBack(_ item: Item, at index: Int) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.insert(item, at: min(index, items.count))
    }

    /// Whether a post named by a list really is still hidden: not while a
    /// change to it is on its way, and not when the list was asked for
    /// before that change finished (Social read it while it was still hidden).
    private func stillHidden(_ id: String, loadBegun generation: Int) -> Bool {
        if working.contains(id) { return false }
        if let left = leftDuring[id], left >= generation { return false }
        return true
    }

    private func read(_ posts: [HiddenPost]) -> [Item] {
        posts.compactMap { hidden in
            MediaPost(post: hidden.post, currentUserId: currentUserId).map {
                Item(post: $0, hiddenAt: hidden.hiddenAt)
            }
        }
    }
}
