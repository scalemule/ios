import Combine
import Foundation
import ScaleMuleCore
import ScaleMuleProfiles
import ScaleMuleSocial

/// The comments under one post, for a comments sheet: pages on demand,
/// names and photos from `PublicProfiles`, a new comment shown at once (and
/// taken back if the server refuses), delete for your own comments and for
/// any comment on your own post.
@MainActor
public final class CommentsModel: ObservableObject {
    @Published public private(set) var comments: [SocialComment] = []
    /// The commenters' public profiles, by person id, as they arrive.
    @Published public private(set) var people: [String: PublicProfile] = [:]
    @Published public private(set) var isLoading = false
    /// The server has answered once (an empty list then means "no comments").
    @Published public private(set) var hasLoaded = false
    @Published public private(set) var hasMore = false
    @Published public private(set) var isSending = false
    /// What went wrong last, in words for the person; nil when nothing did.
    @Published public var errorMessage: String?

    public let postId: String
    public let postAuthorId: String
    public let pageSize: Int
    /// The longest comment Social takes.
    public static let maxLength = 2000
    /// Where a comment just written goes: the bottom (ScaleMule Social lists
    /// comments oldest first), or the top for an app that shows them reversed.
    public var newestFirst = false
    /// The post's comment count changed by this much (+1 sent, -1 deleted).
    public var onCountChange: ((Int) -> Void)?

    private let social: SocialService
    private let profiles: PublicProfiles
    private let currentUserId: String?
    private var nextPage = 1
    private var hidden: Set<String> = []
    private var blocked: Set<String> = []

    public init(postId: String, postAuthorId: String, social: SocialService, profiles: PublicProfiles, currentUserId: String?, pageSize: Int = 30) {
        self.postId = postId
        self.postAuthorId = postAuthorId
        self.social = social
        self.profiles = profiles
        self.currentUserId = currentUserId
        self.pageSize = pageSize
    }

    /// The first page.
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        switch await social.comments(postId: postId, page: 1, perPage: pageSize) {
        case .success(let page):
            comments = visible(page)
            nextPage = 2
            hasMore = page.count >= pageSize
            hasLoaded = true
            errorMessage = nil
            await resolvePeople(page)
        case .failure(let error):
            hasLoaded = true
            errorMessage = error.userFacingMessage
        }
    }

    public func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        guard case .success(let page) = await social.comments(postId: postId, page: nextPage, perPage: pageSize) else { return }
        let known = Set(comments.map(\.id))
        comments.append(contentsOf: visible(page.filter { !known.contains($0.id) }))
        nextPage += 1
        hasMore = page.count >= pageSize
        await resolvePeople(page)
    }

    /// Post a comment. True when the server took it.
    @discardableResult
    public func send(_ text: String, replyingTo parent: SocialComment? = nil) async -> Bool {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !isSending else { return false }
        guard content.count <= Self.maxLength else {
            errorMessage = "That comment is too long (\(Self.maxLength) characters at most)."
            return false
        }
        isSending = true
        defer { isSending = false }
        switch await social.addComment(postId: postId, content: content, replyingTo: parent?.id) {
        case .success(let comment):
            if newestFirst { comments.insert(comment, at: 0) } else { comments.append(comment) }
            errorMessage = nil
            onCountChange?(1)
            await resolvePeople([comment])
            return true
        case .failure(let error):
            errorMessage = error.userFacingMessage
            return false
        }
    }

    /// Your own comment, or any comment on your own post.
    public func canDelete(_ comment: SocialComment) -> Bool {
        guard let currentUserId else { return false }
        return comment.userId == currentUserId || postAuthorId == currentUserId
    }

    public func isMine(_ comment: SocialComment) -> Bool { comment.userId == currentUserId }

    /// Delete a comment (and the replies to it): gone at once, back if the server refuses.
    public func delete(_ comment: SocialComment) async {
        guard canDelete(comment) else { return }
        let before = comments
        comments.removeAll { $0.id == comment.id || $0.parentCommentId == comment.id }
        let removed = before.count - comments.count
        let result = await social.deleteComment(postId: postId, commentId: comment.id)
        if case .failure(let error) = result, error.code != .notFound {
            comments = before
            errorMessage = error.userFacingMessage
        } else {
            onCountChange?(-removed)
        }
    }

    /// A comment the person reported: gone for them straight away.
    public func hide(_ comment: SocialComment) {
        hidden.insert(comment.id)
        comments.removeAll { $0.id == comment.id }
    }

    /// People the person blocked: their comments are not shown.
    public func setBlocked(_ ids: Set<String>) {
        blocked = ids
        comments = visible(comments)
    }

    /// The name to show for a comment's author.
    public func name(for comment: SocialComment, fallback: String = "Someone") -> String {
        let profile = people[comment.userId]
        return profile?.name ?? profile?.username ?? fallback
    }

    private func visible(_ list: [SocialComment]) -> [SocialComment] {
        list.filter { !hidden.contains($0.id) && !blocked.contains($0.userId) }
    }

    private func resolvePeople(_ list: [SocialComment]) async {
        let wanted = Set(list.map(\.userId)).filter { people[$0] == nil }
        guard !wanted.isEmpty else { return }
        let found = await PeopleLookup.profiles(Array(wanted), in: profiles)
        people.merge(found) { _, new in new }
    }
}

/// Looks several people up at once (each is cached by `PublicProfiles`).
enum PeopleLookup {
    static func profiles(_ ids: [String], in profiles: PublicProfiles) async -> [String: PublicProfile] {
        await withTaskGroup(of: (String, PublicProfile?).self) { group in
            for id in ids { group.addTask { (id, await profiles.profile(id)) } }
            var found: [String: PublicProfile] = [:]
            for await (id, profile) in group { if let profile { found[id] = profile } }
            return found
        }
    }
}
