import Combine
import Foundation
import ScaleMuleCore
import ScaleMuleProfiles
import ScaleMuleSocial

/// One person's page: who they are, how many follow them, whether you do,
/// and their posts (pages on demand). Works for the signed-in person too.
@MainActor
public final class PersonProfileModel: ObservableObject {
    public let userId: String
    @Published public private(set) var profile: PublicProfile?
    @Published public private(set) var followersCount: Int?
    @Published public private(set) var followingCount: Int?
    /// They follow the signed-in person.
    @Published public private(set) var followsMe = false
    @Published public private(set) var posts: [MediaPost] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasLoaded = false
    @Published public private(set) var hasMore = false
    @Published public private(set) var isLoadingMore = false
    @Published public private(set) var errorMessage: String?

    public let pageSize: Int
    public let isMe: Bool
    private let social: SocialService
    private let profiles: PublicProfiles
    private let follows: FollowStore
    private let currentUserId: String?
    private var nextPage = 1

    public init(userId: String, social: SocialService, profiles: PublicProfiles, follows: FollowStore, currentUserId: String?, pageSize: Int = 30) {
        self.userId = userId
        self.social = social
        self.profiles = profiles
        self.follows = follows
        self.currentUserId = currentUserId
        self.pageSize = pageSize
        isMe = userId == currentUserId
    }

    /// Profile, counts and the first page of posts, together.
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        async let person = profiles.profile(userId)
        async let status = social.followStatus(userId: userId)
        async let page = social.userPosts(userId: userId, page: 1, perPage: pageSize)
        if let person = await person { profile = person }
        if case .success(let status) = await status {
            followersCount = status.followersCount
            followingCount = status.followingCount
            followsMe = status.isFollowedBy
            if !isMe { follows.note(userId, following: status.isFollowing) }
        }
        switch await page {
        case .success(let list):
            posts = list.compactMap { MediaPost(post: $0, currentUserId: currentUserId) }
            nextPage = 2
            hasMore = list.count >= pageSize
            errorMessage = nil
        case .failure(let error):
            errorMessage = error.userFacingMessage
        }
        hasLoaded = true
    }

    public func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard case .success(let list) = await social.userPosts(userId: userId, page: nextPage, perPage: pageSize) else { return }
        let known = Set(posts.map(\.id))
        posts.append(contentsOf: list.compactMap { MediaPost(post: $0, currentUserId: currentUserId) }.filter { !known.contains($0.id) })
        nextPage += 1
        hasMore = list.count >= pageSize
    }

    /// Whether the signed-in person follows them (nil until known).
    public var isFollowing: Bool? { follows.isFollowing(userId) }

    /// Follow or unfollow them; the follower count moves with it.
    @discardableResult
    public func toggleFollow() async -> ApiError? {
        guard !isMe else { return nil }
        let wasFollowing = follows.isFollowing(userId) ?? false
        if let count = followersCount { followersCount = max(0, count + (wasFollowing ? -1 : 1)) }
        let error = await follows.toggle(userId)
        if error != nil, let count = followersCount { followersCount = max(0, count + (wasFollowing ? 1 : -1)) }
        return error
    }

    /// A post was deleted elsewhere in the app.
    public func remove(postId: String) {
        posts.removeAll { $0.id == postId }
    }
}

/// A person's followers, or the people they follow, with names and photos.
@MainActor
public final class PeopleListModel: ObservableObject {
    public enum Kind: Sendable { case followers, following }

    public let userId: String
    public let kind: Kind
    @Published public private(set) var entries: [FollowEntry] = []
    @Published public private(set) var people: [String: PublicProfile] = [:]
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasLoaded = false
    @Published public private(set) var hasMore = false
    @Published public private(set) var errorMessage: String?

    public let pageSize: Int
    private let social: SocialService
    private let profiles: PublicProfiles
    private var nextPage = 1

    public init(userId: String, kind: Kind, social: SocialService, profiles: PublicProfiles, pageSize: Int = 50) {
        self.userId = userId
        self.kind = kind
        self.social = social
        self.profiles = profiles
        self.pageSize = pageSize
    }

    public func load() async {
        nextPage = 1
        await fetch(replacing: true)
    }

    public func loadMore() async {
        guard hasMore else { return }
        await fetch(replacing: false)
    }

    private func fetch(replacing: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let result = kind == .followers
            ? await social.followers(userId: userId, page: nextPage, perPage: pageSize)
            : await social.following(userId: userId, page: nextPage, perPage: pageSize)
        switch result {
        case .success(let page):
            let known = replacing ? [] : Set(entries.map(\.id))
            entries = (replacing ? [] : entries) + page.filter { !known.contains($0.id) }
            nextPage += 1
            hasMore = page.count >= pageSize
            errorMessage = nil
            let wanted = page.map(\.userId).filter { people[$0] == nil }
            let found = await PeopleLookup.profiles(wanted, in: profiles)
            people.merge(found) { _, new in new }
        case .failure(let error):
            errorMessage = error.userFacingMessage
        }
        hasLoaded = true
    }
}
