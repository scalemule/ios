import Combine
import Foundation
import ScaleMuleCore

/// A durable notification. Delivery and reading are separate: receiving a push
/// never marks this item read, and clearing the app icon does not change it.
public struct InboxNotification: Decodable, Identifiable, Sendable {
    public let id: String
    public let kind: String
    public let title: String
    public let body: String
    public let actionUrl: String?
    public let data: [String: AnyCodable]?
    public var isRead: Bool
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, kind, title, body, data
        case actionUrl = "action_url", isRead = "is_read", createdAt = "created_at"
    }
}

public struct NotificationPage: Decodable, Sendable {
    public let notifications: [InboxNotification]
    public let hasMore: Bool
    public let nextCursor: String?
    enum CodingKeys: String, CodingKey {
        case notifications, hasMore = "has_more", nextCursor = "next_cursor"
    }
}

public protocol NotificationInboxServing: Sendable {
    func list(cursor: String?) async -> ApiResponse<NotificationPage>
    func unreadCount() async -> ApiResponse<Int>
    func markRead(id: String) async -> ApiResponse<Void>
    func markAllRead() async -> ApiResponse<Void>
}

/// User-scoped notification APIs. Ownership comes from the session, never a
/// user ID in a request body or a push payload.
public final class NotificationInboxService: ServiceModule, NotificationInboxServing, @unchecked Sendable {
    public let client: HTTPClient
    public required init(client: HTTPClient) { self.client = client }
    public convenience init(app: ScaleMuleApp) { self.init(client: app.client) }

    public func list(cursor: String? = nil) async -> ApiResponse<NotificationPage> {
        var query = ["limit": "30"]
        if let cursor { query["cursor"] = cursor }
        return await client.request(RequestOptions(method: .get, path: "/v1/notifications",
            query: query, credential: .sessionToken))
    }

    public func unreadCount() async -> ApiResponse<Int> {
        struct Count: Decodable, Sendable { let count: Int }
        let result: ApiResponse<Count> = await client.request(RequestOptions(method: .get,
            path: "/v1/notifications/unread-count", credential: .sessionToken))
        switch result {
        case .success(let value): return .success(max(0, value.count))
        case .failure(let error): return .failure(error)
        }
    }

    public func markRead(id: String) async -> ApiResponse<Void> {
        guard let uuid = UUID(uuidString: id) else {
            return .failure(ApiError(code: .unknown, message: "Invalid notification ID."))
        }
        return await mutate(RequestOptions(method: .patch,
            path: "/v1/notifications/\(uuid.uuidString.lowercased())/read", credential: .sessionToken))
    }

    public func markAllRead() async -> ApiResponse<Void> {
        await mutate(RequestOptions(method: .patch,
            path: "/v1/notifications/read-all", credential: .sessionToken))
    }
    private func mutate(_ options: RequestOptions) async -> ApiResponse<Void> {
        switch await client.requestVoid(options) {
        case .success: return .success(())
        case .failure(let error): return .failure(error)
        }
    }

}

@MainActor
public final class NotificationInboxModel: ObservableObject {
    @Published public private(set) var items: [InboxNotification] = []
    @Published public private(set) var unread = 0
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasLoaded = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var hasMore = false
    private var service: (any NotificationInboxServing)?
    private var userId: String?
    private var generation = UUID()
    private var revision = 0
    private var countRequest = 0
    private var nextCursor: String?
    private var reading: Set<String> = []
    private var acknowledged: Set<String> = []
    private var pollTask: Task<Void, Never>?

    public init() {}
    deinit { pollTask?.cancel() }

    public func attach(service: any NotificationInboxServing, userId: String) {
        if self.userId != userId { reset() }
        self.service = service
        self.userId = userId
    }

    public func reset() {
        pollTask?.cancel(); pollTask = nil
        generation = UUID(); revision += 1
        service = nil; userId = nil
        items = []; unread = 0; isLoading = false; hasLoaded = false
        errorMessage = nil; hasMore = false; nextCursor = nil; reading = []; acknowledged = []
    }

    public func load(more: Bool = false) async {
        guard let service, !isLoading, !more || (hasMore && nextCursor != nil) else { return }
        let scope = generation
        isLoading = true
        let result = await service.list(cursor: more ? nextCursor : nil)
        guard generation == scope else { return }
        isLoading = false; hasLoaded = true
        switch result {
        case .success(let page):
            // Do not restore stale unread flags after a read completed in flight.
            let readIds = Set(items.filter(\.isRead).map(\.id)).union(acknowledged)
            let incoming = page.notifications.map { item in
                var item = item
                if readIds.contains(item.id) { item.isRead = true }
                return item
            }
            if more {
                let existing = Set(items.map(\.id))
                items += incoming.filter { !existing.contains($0.id) }
            } else { items = incoming }
            acknowledged.removeAll()
            nextCursor = page.nextCursor
            hasMore = page.hasMore && page.nextCursor != nil
            errorMessage = nil
        case .failure(let error): errorMessage = error.userFacingMessage
        }
        await refreshUnread()
    }

    public func refreshUnread() async {
        guard let service else { return }
        countRequest += 1
        let request = countRequest
        let scope = generation, version = revision
        let result = await service.unreadCount()
        guard generation == scope, revision == version, countRequest == request else { return }
        if case .success(let count) = result { unread = max(0, count) }
    }

    /// Call only for an item the person actually viewed, or a push they tapped.
    /// Keep its unread state on failure so the app never pretends a write worked.
    public func markRead(id: String) async {
        guard let service, !reading.contains(id), items.first(where: { $0.id == id })?.isRead != true else { return }
        let scope = generation
        reading.insert(id)
        let result = await service.markRead(id: id)
        guard generation == scope else { return }
        reading.remove(id)
        switch result {
        case .success:
            revision += 1
            acknowledged.insert(id)
            errorMessage = nil
            if let index = items.firstIndex(where: { $0.id == id }) { items[index].isRead = true }
            // Query the authoritative count: parallel reads and new arrivals
            // must not be approximated with local decrements.
            await refreshUnread()
        case .failure(let error): errorMessage = error.userFacingMessage
        }
    }

    public func markAllRead() async {
        guard let service else { return }
        let scope = generation
        let visibleIds = Set(items.map(\.id))
        let result = await service.markAllRead()
        guard generation == scope else { return }
        switch result {
        case .success:
            revision += 1
            items = items.map { item in
                var item = item
                if visibleIds.contains(item.id) { item.isRead = true }
                return item
            }
            await refreshUnread()
        case .failure(let error): errorMessage = error.userFacingMessage
        }
    }

    public func startPolling(every seconds: TimeInterval = 30) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshUnread()
                do { try await Task.sleep(for: .seconds(max(5, seconds))) }
                catch { return }
            }
        }
    }
}
