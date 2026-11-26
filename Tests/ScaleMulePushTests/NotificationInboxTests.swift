import XCTest
import ScaleMuleCore
import ScaleMuleTestHelpers
@testable import ScaleMulePush

private let notificationID = "019b0000-0000-7000-8000-000000000011"

private actor InboxServer: NotificationInboxServing {
    var reads: [String] = []
    var count = 1
    var failRead = false
    var holdList = false
    var waiting: CheckedContinuation<ApiResponse<NotificationPage>, Never>?
    func configure(fail: Bool = false, hold: Bool = false) { failRead = fail; holdList = hold }
    func list(cursor: String?) async -> ApiResponse<NotificationPage> {
        if holdList { return await withCheckedContinuation { waiting = $0 } }
        return .success(Self.page())
    }
    func unreadCount() async -> ApiResponse<Int> { .success(count) }
    func markRead(id: String) async -> ApiResponse<Void> {
        if failRead { return .failure(.network("offline")) }
        reads.append(id); count = 0; return .success(())
    }
    func markAllRead() async -> ApiResponse<Void> { count = 0; return .success(()) }
    func release() { waiting?.resume(returning: .success(Self.page())); waiting = nil }
    func isWaiting() -> Bool { waiting != nil }
    static func page() -> NotificationPage {
        NotificationPage(notifications: [InboxNotification(id: notificationID, kind: "admin.push",
            title: "Здравей 👋", body: "A new notification", actionUrl: nil, data: nil,
            isRead: false, createdAt: "2026-11-25T18:00:00Z")], hasMore: false, nextCursor: nil)
    }
}

@MainActor final class NotificationInboxTests: XCTestCase {
    func testLoadingOrRefreshingNeverMarksNotificationsRead() async {
        let server = InboxServer(), model = NotificationInboxModel()
        model.attach(service: server, userId: "alice")
        await model.load()
        XCTAssertEqual(model.unread, 1)
        XCTAssertFalse(model.items[0].isRead)
        let reads = await server.reads
        XCTAssertTrue(reads.isEmpty)
    }

    func testReadingAVisibleNotificationUpdatesServerAndBadge() async {
        let server = InboxServer(), model = NotificationInboxModel()
        model.attach(service: server, userId: "alice")
        await model.load()
        await model.markRead(id: notificationID)
        XCTAssertEqual(model.unread, 0)
        XCTAssertTrue(model.items[0].isRead)
        await model.markRead(id: notificationID)
        let reads = await server.reads
        XCTAssertEqual(reads, [notificationID])
    }

    func testFailedReadPreservesUnreadAndAllowsRetry() async {
        let server = InboxServer(), model = NotificationInboxModel()
        model.attach(service: server, userId: "alice")
        await model.load(); await server.configure(fail: true)
        await model.markRead(id: notificationID)
        XCTAssertEqual(model.unread, 1)
        XCTAssertFalse(model.items[0].isRead)
        XCTAssertNotNil(model.errorMessage)
        await server.configure()
        await model.markRead(id: notificationID)
        XCTAssertEqual(model.unread, 0)
    }

    func testLateResponseCannotRestorePreviousAccountsInbox() async {
        let server = InboxServer(), model = NotificationInboxModel()
        model.attach(service: server, userId: "alice")
        await server.configure(hold: true)
        let task = Task { await model.load() }
        while !(await server.isWaiting()) { await Task.yield() }
        model.reset()
        model.attach(service: InboxServer(), userId: "bob")
        await server.release(); await task.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.unread, 0)
        XCTAssertFalse(model.isLoading)
    }

    func testReadingWhileRefreshIsInFlightDoesNotRestoreUnreadState() async {
        let server = InboxServer(), model = NotificationInboxModel()
        model.attach(service: server, userId: "alice")
        await model.load(); await server.configure(hold: true)
        let task = Task { await model.load() }
        while !(await server.isWaiting()) { await Task.yield() }
        await model.markRead(id: notificationID)
        await server.release(); await task.value
        XCTAssertEqual(model.unread, 0)
        XCTAssertTrue(model.items[0].isRead)
    }
}

#if os(macOS)
final class NotificationInboxHTTPTests: XCTestCase {
    override func tearDown() { MockURLProtocol.requestHandler = nil; super.tearDown() }

    func testListAndCountUseTheSignedInSessionAndDecodeBareAPIResponses() async throws {
        let (app, _) = createTestClient()
        try await app.sessionManager.setCredentials(CredentialSet(sessionToken: "user-session", accessToken: "not-this-jwt", sessionExpiresAt: Date().addingTimeInterval(3600)))
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user-session")
            if request.url?.path.hasSuffix("unread-count") == true {
                return TestFixtures.mockResponse(statusCode: 200, json: "{\"count\":3}")
            }
            XCTAssertEqual(request.url?.path, "/v1/communication/notifications")
            return TestFixtures.mockResponse(statusCode: 200, json: """
            {"notifications":[{"id":"\(notificationID)","kind":"admin.push","title":"世界 👋","body":"Hello","is_read":false,"created_at":"2026-11-25T18:00:00Z","data":null}],"has_more":true,"next_cursor":"2026-11-25T18:00:00Z|\(notificationID)"}
            """)
        }
        let service = NotificationInboxService(app: app)
        let page = await service.list()
        XCTAssertEqual(page.data?.notifications.first?.title, "世界 👋")
        XCTAssertNotNil(page.data?.nextCursor)
        let count = await service.unreadCount()
        XCTAssertEqual(count.data, 3)
    }

    func testEarlierPagePreservesCursorTimezoneOffset() async throws {
        let (app, _) = createTestClient()
        let cursor = "2026-11-25T18:00:00+00:00|\(notificationID)"
        MockURLProtocol.requestHandler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.percentEncodedQuery!
            let parameter = query.split(separator: "&").first { $0.hasPrefix("cursor=") }!
            let decoded = String(parameter.dropFirst(7)).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            XCTAssertEqual(decoded, cursor)
            return TestFixtures.mockResponse(statusCode: 200, json: "{\"notifications\":[],\"has_more\":false}")
        }
        let result = await NotificationInboxService(app: app).list(cursor: cursor)
        XCTAssertTrue(result.isSuccess)
    }

    func testReadTargetsOnlyTheSpecifiedItemAndRejectsInvalidIdentifiers() async throws {
        let (app, _) = createTestClient()
        try await app.sessionManager.setCredentials(CredentialSet(sessionToken: "user-session", sessionExpiresAt: Date().addingTimeInterval(3600)))
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url?.path, "/v1/communication/notifications/\(notificationID)/read")
            return TestFixtures.mockResponse(statusCode: 204, json: "")
        }
        let service = NotificationInboxService(app: app)
        let result = await service.markRead(id: notificationID)
        XCTAssertTrue(result.isSuccess)
        MockURLProtocol.requestHandler = { _ in XCTFail("Unsafe ID must not be sent"); throw URLError(.badURL) }
        let invalid = await service.markRead(id: "../read-all")
        XCTAssertFalse(invalid.isSuccess)
    }
}
#endif

private actor PagedInboxServer: NotificationInboxServing {
    var allRead = false
    var failBulk = false
    var bulkCalls = 0
    var holdNextList = false
    private var waiting: CheckedContinuation<ApiResponse<NotificationPage>, Never>?
    private var heldPage: NotificationPage?

    func configure(fail: Bool = false, hold: Bool = false) { failBulk = fail; holdNextList = hold }
    func isWaiting() -> Bool { waiting != nil }
    func release() { if let heldPage { waiting?.resume(returning: .success(heldPage)) }; waiting = nil }
    func list(cursor: String?) async -> ApiResponse<NotificationPage> {
        let start = cursor == nil ? 0 : 30
        let end = min(49, start + 30)
        let page = NotificationPage(notifications: (start..<end).map { index in
            InboxNotification(id: String(format: "019b0000-0000-7000-8000-%012d", 100 - index),
                kind: "admin.push", title: "Update \(index)", body: "世界 👋", actionUrl: nil, data: nil,
                isRead: allRead, createdAt: "2026-11-25T18:00:00Z")
        }, hasMore: end < 49, nextCursor: end < 49 ? "next" : nil)
        if holdNextList {
            holdNextList = false; heldPage = page
            return await withCheckedContinuation { waiting = $0 }
        }
        return .success(page)
    }
    func unreadCount() async -> ApiResponse<Int> { .success(allRead ? 0 : 49) }
    func markRead(id: String) async -> ApiResponse<Void> { .success(()) }
    func markAllRead() async -> ApiResponse<Void> {
        bulkCalls += 1
        if failBulk { return .failure(.network("offline")) }
        allRead = true
        return .success(())
    }
}

@MainActor final class NotificationInboxBulkTests: XCTestCase {
    func testOneBulkAcknowledgementClears49IncludingUnloadedPages() async {
        let server = PagedInboxServer(), model = NotificationInboxModel()
        model.attach(service: server, userId: "alice")
        await model.load()
        XCTAssertEqual(model.items.count, 30)
        XCTAssertEqual(model.unread, 49)
        await model.markAllRead()
        XCTAssertEqual(model.unread, 0)
        XCTAssertTrue(model.items.allSatisfy(\.isRead))
        await model.load(more: true)
        XCTAssertEqual(model.items.count, 49)
        XCTAssertTrue(model.items.allSatisfy(\.isRead))
        let calls = await server.bulkCalls
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(model.hasMore)
    }

    func testFailedBulkReadRetainsCountAndRetryClearsError() async {
        let server = PagedInboxServer(), model = NotificationInboxModel()
        model.attach(service: server, userId: "alice")
        await model.load(); await server.configure(fail: true)
        await model.markAllRead()
        XCTAssertEqual(model.unread, 49)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isMarkingAllRead)
        await server.configure()
        await model.markAllRead()
        XCTAssertEqual(model.unread, 0)
        XCTAssertNil(model.errorMessage)
    }

    func testRefreshKeepsEarlierPagesAlreadyLoaded() async {
        let server = PagedInboxServer(), model = NotificationInboxModel()
        model.attach(service: server, userId: "alice")
        await model.load(); await model.load(more: true)
        let ids = model.items.map(\.id)
        await model.load()
        XCTAssertEqual(model.items.map(\.id), ids)
        XCTAssertEqual(model.items.count, 49)
        XCTAssertFalse(model.hasMore)
    }

    func testBulkReadDuringPageRequestCannotRestoreUnreadRows() async {
        let server = PagedInboxServer(), model = NotificationInboxModel()
        model.attach(service: server, userId: "alice")
        await server.configure(hold: true)
        let loading = Task { await model.load() }
        while !(await server.isWaiting()) { await Task.yield() }
        await model.markAllRead()
        await server.release(); await loading.value
        XCTAssertEqual(model.unread, 0)
        XCTAssertTrue(model.items.allSatisfy(\.isRead))
        XCTAssertEqual(model.items.count, 30)
    }
}
