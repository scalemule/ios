import Combine
import Foundation
import ScaleMuleCore
import ScaleMuleSocial

/// Who the signed-in person follows, as far as the app has learned it: from
/// posts (`MediaPost.authorFollowed`), from a profile's `FollowStatus`, and
/// from their own taps. One store for the whole app, so the Follow button on
/// a post, a profile and a list always agree.
///
/// A tap shows at once and is put back if the server refuses.
@MainActor
public final class FollowStore: ObservableObject {
    /// Known answers by person id; a person not in it is unknown.
    @Published public private(set) var states: [String: Bool] = [:]
    /// People whose follow or unfollow is on its way to the server.
    @Published public private(set) var busy: Set<String> = []

    private var social: SocialService?
    private var currentUserId: String?
    /// People the person followed or unfollowed here: an older answer from
    /// the server (a feed page loaded before the tap) never undoes that.
    private var changedHere: Set<String> = []

    public init() {}

    /// Connect to the signed-in person's Social. Another person signing in
    /// starts from nothing.
    public func attach(social: SocialService, currentUserId: String?) {
        if currentUserId != self.currentUserId { reset() }
        self.social = social
        self.currentUserId = currentUserId
    }

    public func reset() {
        states = [:]
        busy = []
        changedHere = []
    }

    /// Whether the person follows `userId`; nil when not known yet.
    public func isFollowing(_ userId: String) -> Bool? { states[userId] }

    /// A Follow button makes sense: someone else, known not to be followed.
    public func canFollow(_ userId: String) -> Bool {
        userId != currentUserId && states[userId] == false
    }

    /// What the server said about one person.
    public func note(_ userId: String, following: Bool) {
        guard !changedHere.contains(userId), !busy.contains(userId), states[userId] != following else { return }
        states[userId] = following
    }

    /// What a page of posts says about their authors.
    public func note(posts: [MediaPost]) {
        for post in posts {
            if let followed = post.authorFollowed, !post.isMine { note(post.authorId, following: followed) }
        }
    }

    /// Ask the server about one person (a profile being opened).
    @discardableResult
    public func refresh(_ userId: String) async -> FollowStatus? {
        guard let social, case .success(let status) = await social.followStatus(userId: userId) else { return nil }
        note(userId, following: status.isFollowing)
        return status
    }

    /// Follow or unfollow. Returns the error when the server refused (the
    /// button is back where it was).
    @discardableResult
    public func setFollowing(_ userId: String, _ follow: Bool) async -> ApiError? {
        guard let social else { return ApiError(code: .unauthorized, message: "Sign in to follow people.") }
        guard userId != currentUserId, !busy.contains(userId) else { return nil }
        let before = states[userId]
        states[userId] = follow
        changedHere.insert(userId)
        busy.insert(userId)
        defer { busy.remove(userId) }
        let result = follow ? await social.follow(userId: userId) : await social.unfollow(userId: userId)
        guard case .failure(let error) = result else { return nil }
        // Already following, or already not: that is where the person wanted to be.
        if follow ? error.code == .conflict : error.code == .notFound { return nil }
        states[userId] = before
        if before == nil { changedHere.remove(userId) }
        return error
    }

    /// Follow when not following (or unknown), unfollow when following.
    @discardableResult
    public func toggle(_ userId: String) async -> ApiError? {
        await setFollowing(userId, !(states[userId] ?? false))
    }
}
