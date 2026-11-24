import Combine
import Foundation
import ScaleMuleCore
import ScaleMuleProfiles
import ScaleMuleSocial

/// The signed-in person's activity inbox: who followed them, liked their
/// posts, commented or replied, newest first, with an unread count for a tab
/// badge.
@MainActor
public final class ActivityInboxModel: ObservableObject {
    @Published public private(set) var items: [SocialActivity] = []
    /// The public profiles of the people who did those things, as they arrive.
    @Published public private(set) var people: [String: PublicProfile] = [:]
    /// Entries not read yet (the badge).
    @Published public private(set) var unread = 0
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasLoaded = false
    @Published public private(set) var errorMessage: String?

    public let limit: Int
    private var social: SocialService?
    private var profiles: PublicProfiles?
    private var blocked: Set<String> = []
    private var pollTask: Task<Void, Never>?

    public init(limit: Int = 100) {
        self.limit = limit
    }

    public func attach(social: SocialService, profiles: PublicProfiles) {
        self.social = social
        self.profiles = profiles
    }

    /// Signed out: nothing of the last person stays.
    public func reset() {
        stopPolling()
        items = []
        people = [:]
        unread = 0
        hasLoaded = false
        errorMessage = nil
    }

    public func load() async {
        guard let social, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        switch await social.activity(limit: limit) {
        case .success(let list):
            items = list.filter { !blocked.contains($0.actorUserId) }
            unread = items.filter { !$0.isRead }.count
            hasLoaded = true
            errorMessage = nil
            await resolvePeople(items)
        case .failure(let error):
            hasLoaded = true
            errorMessage = error.userFacingMessage
        }
    }

    /// Only the count, for the badge (cheap; call it when the app opens or a push arrives).
    public func refreshUnread() async {
        guard let social, case .success(let count) = await social.unreadActivityCount() else { return }
        unread = max(0, count)
    }

    /// The person opened the inbox: nothing is unread any more.
    public func markAllRead() async {
        guard let social, unread > 0 || items.contains(where: { !$0.isRead }) else { return }
        let before = (items, unread)
        items = items.map(Self.read)
        unread = 0
        if case .failure = await social.markAllActivityRead() { (items, unread) = before }
    }

    /// People the person blocked: what they did is not shown.
    public func setBlocked(_ ids: Set<String>) {
        blocked = ids
        items.removeAll { ids.contains($0.actorUserId) }
    }

    /// The name to show for who did it.
    public func name(for item: SocialActivity, fallback: String = "Someone") -> String {
        let profile = people[item.actorUserId]
        return profile?.name ?? profile?.username ?? fallback
    }

    /// Look at the unread count every `seconds` until `stopPolling()`.
    public func startPolling(every seconds: TimeInterval = 60) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshUnread()
                try? await Task.sleep(nanoseconds: UInt64(max(5, seconds) * 1_000_000_000))
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private static func read(_ item: SocialActivity) -> SocialActivity {
        SocialActivity(id: item.id, type: item.type, actorUserId: item.actorUserId, targetType: item.targetType,
                       targetId: item.targetId, metadata: item.metadata, isRead: true, createdAt: item.createdAt)
    }

    private func resolvePeople(_ list: [SocialActivity]) async {
        guard let profiles else { return }
        let wanted = Set(list.map(\.actorUserId)).filter { !$0.isEmpty && people[$0] == nil }
        guard !wanted.isEmpty else { return }
        let found = await PeopleLookup.profiles(Array(wanted), in: profiles)
        people.merge(found) { _, new in new }
    }
}
