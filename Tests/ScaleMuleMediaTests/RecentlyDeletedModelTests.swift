import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleMediaPosts
@testable import ScaleMuleSocial

/// The "Recently deleted" list against a mocked Social that answers as
/// scalemule-social does (`GET /posts/deleted`, `POST /posts/{id}/restore`).
@MainActor
final class RecentlyDeletedModelTests: XCTestCase {
    private let me = "019b0000-0000-7000-8000-0000000000aa"

    private func model(pageSize: Int = 30) async -> RecentlyDeletedModel {
        let (app, _) = createTestClient()
        try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600)))
        let model = RecentlyDeletedModel(pageSize: pageSize)
        model.attach(social: SocialService(app: app), currentUserId: me)
        return model
    }

    private func stamp(daysFromNow days: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(days * 86_400))
    }

    /// A post as Social lists it; `deletedDaysAgo` nil is the post itself (a restore's answer).
    private func post(_ id: String, kind: String = "photo", deletedDaysAgo: Double? = 1, keptDays: Double = 30, media: Bool = true) -> String {
        var fields = [
            #""id":"\#(id)""#, #""user_id":"\#(me)""#, #""content":"Oakland, CA""#, #""media_urls":null"#,
            #""visibility":"public""#, #""likes_count":2"#, #""liked_by_me":false"#, #""viewer_follows_author":false"#,
            #""comments_count":1"#, #""shares_count":0"#,
            #""metadata":{"kind":"\#(kind)","author_name":"Sam","width":1080,"height":1920}"#,
            #""created_at":"\#(stamp(daysFromNow: -10))""#,
        ]
        if media { fields.append(#""media_ids":["m-\#(id)"]"#) }
        if let deletedDaysAgo {
            fields.append(#""deleted_at":"\#(stamp(daysFromNow: -deletedDaysAgo))""#)
            fields.append(#""restorable_until":"\#(stamp(daysFromNow: keptDays - deletedDaysAgo))""#)
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private func list(_ posts: [String], by restorer: String = "author") -> (HTTPURLResponse, Data) {
        TestFixtures.envelopedResponse(json: #"{"posts":[\#(posts.joined(separator: ","))],"restorable_by":"\#(restorer)"}"#)
    }

    private func page(of request: URLRequest) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
    }

    private func refusal(_ status: Int, _ code: String, _ message: String) -> (HTTPURLResponse, Data) {
        TestFixtures.mockResponse(statusCode: status, json: #"{"success":false,"error":{"code":"\#(code)","message":"\#(message)"}}"#)
    }

    // MARK: Loading

    func testListsDeletedPostsWithTheDaysTheyHaveLeft() async {
        let model = await model()
        XCTAssertFalse(model.hasLoaded)
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/social/posts/deleted")
            return self.list([
                self.post("today", deletedDaysAgo: 0.01),
                self.post("clip", kind: "video", deletedDaysAgo: 12.5),
                self.post("last-day", deletedDaysAgo: 29.6),
                self.post("words-only", media: false),
            ])
        }
        await model.load()
        XCTAssertTrue(model.hasLoaded)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.canRestore)
        XCTAssertFalse(model.hasMore)
        XCTAssertEqual(model.items.map(\.id), ["today", "clip", "last-day"], "as Social ordered them; a post with no photo or video has no tile")
        XCTAssertEqual(model.items.map { $0.daysLeft() }, [30, 18, 1])
        XCTAssertEqual(model.items[1].post.isVideo, true)
        XCTAssertEqual(model.items[0].post.mediaId, "m-today", "the photo is still named")
        XCTAssertTrue(model.items[0].post.isMine)
        XCTAssertNotNil(model.items[0].deletedAt)
        XCTAssertEqual(model.items[0].daysLeft(now: Date().addingTimeInterval(40 * 86_400)), 0)
    }

    func testNothingDeletedIsAnEmptyLoadedList() async {
        let model = await model()
        MockURLProtocol.requestHandler = { _ in self.list([]) }
        await model.load()
        XCTAssertTrue(model.hasLoaded)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testAFailedLoadSaysWhatToDoAndKeepsWhatWasShown() async {
        let model = await model()
        MockURLProtocol.requestHandler = { _ in self.list([self.post("a")]) }
        await model.load()
        MockURLProtocol.requestHandler = { _ in self.refusal(500, "INTERNAL_ERROR", "An internal error occurred") }
        await model.load()
        XCTAssertEqual(model.items.map(\.id), ["a"])
        XCTAssertEqual(model.errorMessage, "Something went wrong on our side. Please try again in a minute.")
        XCTAssertFalse(model.isLoading)

        MockURLProtocol.requestHandler = { _ in self.list([self.post("a")]) }
        await model.load()
        XCTAssertNil(model.errorMessage, "a load that works clears it")
    }

    func testPagesOnDemandWithoutRepeats() async {
        let model = await model(pageSize: 2)
        var asked: [String] = []
        MockURLProtocol.requestHandler = { request in
            let page = self.page(of: request) ?? "?"
            asked.append(page)
            // A post was deleted between the two pages: "b" shows up again.
            return page == "1" ? self.list([self.post("a"), self.post("b")]) : self.list([self.post("b"), self.post("c")])
        }
        await model.load()
        XCTAssertTrue(model.hasMore)
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(asked, ["1", "2"])
        XCTAssertTrue(model.hasMore, "a full page: there may be another")
        MockURLProtocol.requestHandler = { _ in self.list([]) }
        await model.loadMore()
        XCTAssertFalse(model.hasMore)
    }

    // MARK: Restoring

    func testRestoreTakesThePostOutAtOnceAndHandsItToTheFeed() async {
        let model = await model()
        MockURLProtocol.requestHandler = { _ in self.list([self.post("a"), self.post("b"), self.post("c")]) }
        await model.load()

        var restored: [MediaPost] = []
        model.onRestored = { restored.append($0) }
        var whileAsking: [String] = []
        var busyWhileAsking = false
        var requests: [String] = []
        MockURLProtocol.requestHandler = { request in
            requests.append("\(request.httpMethod ?? "") \(request.url!.path)")
            DispatchQueue.main.sync {
                whileAsking = model.items.map(\.id)
                busyWhileAsking = model.restoring.contains("b")
            }
            return TestFixtures.envelopedResponse(json: self.post("b", deletedDaysAgo: nil))
        }
        let back = await model.restore(model.items[1])
        XCTAssertEqual(requests, ["POST /v1/social/posts/b/restore"])
        XCTAssertEqual(whileAsking, ["a", "c"], "gone before the server answered")
        XCTAssertTrue(busyWhileAsking)
        XCTAssertEqual(model.items.map(\.id), ["a", "c"])
        XCTAssertTrue(model.restoring.isEmpty)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(back?.id, "b")
        XCTAssertEqual(back?.mediaId, "m-b")
        XCTAssertEqual(back?.likes, 2, "its likes came back with it")
        XCTAssertEqual(restored.map(\.id), ["b"])
    }

    func testARefusedRestorePutsThePostBackWhereItWas() async {
        let model = await model()
        MockURLProtocol.requestHandler = { _ in self.list([self.post("a"), self.post("b"), self.post("c")]) }
        await model.load()
        var restored = 0
        model.onRestored = { _ in restored += 1 }

        MockURLProtocol.requestHandler = { _ in self.refusal(500, "INTERNAL_ERROR", "An internal error occurred") }
        let failed = await model.restore(model.items[1])
        XCTAssertNil(failed)
        XCTAssertEqual(model.items.map(\.id), ["a", "b", "c"], "back in its place")
        XCTAssertEqual(model.errorMessage, "Something went wrong on our side. Please try again in a minute.")
        XCTAssertTrue(model.restoring.isEmpty)
        XCTAssertEqual(restored, 0)

        // Offline: the same, in other words.
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        let offline = await model.restore(model.items[2])
        XCTAssertNil(offline)
        XCTAssertEqual(model.items.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(model.errorMessage, "You seem to be offline. Check your connection and try again.")

        // Trying again works and clears the message.
        MockURLProtocol.requestHandler = { _ in TestFixtures.envelopedResponse(json: self.post("c", deletedDaysAgo: nil)) }
        let worked = await model.restore(model.items[2])
        XCTAssertEqual(worked?.id, "c")
        XCTAssertEqual(model.items.map(\.id), ["a", "b"])
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(restored, 1)
    }

    func testAPostWhoseTimeRanOutLeavesTheList() async {
        let model = await model()
        MockURLProtocol.requestHandler = { _ in self.list([self.post("a"), self.post("late"), self.post("gone")]) }
        await model.load()

        MockURLProtocol.requestHandler = { _ in self.refusal(410, "RESTORE_WINDOW_EXPIRED", "This post was deleted too long ago to be restored") }
        let late = await model.restore(model.items[1])
        XCTAssertNil(late)
        XCTAssertEqual(model.items.map(\.id), ["a", "gone"], "nothing to bring back: it does not return to the list")
        XCTAssertEqual(model.errorMessage, "This post was deleted too long ago and can't be restored any more.")

        // Already removed for good between the list and the tap.
        MockURLProtocol.requestHandler = { _ in self.refusal(404, "NOT_FOUND", "Post not found") }
        let gone = await model.restore(model.items[1])
        XCTAssertNil(gone)
        XCTAssertEqual(model.items.map(\.id), ["a"])
        XCTAssertEqual(model.errorMessage, "This post was deleted too long ago and can't be restored any more.")
    }

    func testWhereOnlyTheTeamRestoresNothingIsAsked() async {
        let model = await model()
        MockURLProtocol.requestHandler = { _ in self.list([self.post("a")], by: "team") }
        await model.load()
        XCTAssertEqual(model.restorableBy, .team)
        XCTAssertFalse(model.canRestore)
        XCTAssertEqual(model.items.map(\.id), ["a"], "still listed, with its days")

        var asked = 0
        MockURLProtocol.requestHandler = { _ in
            asked += 1
            return self.refusal(403, "FORBIDDEN", "Only the app's team can restore a deleted post in this app")
        }
        let refused = await model.restore(model.items[0])
        XCTAssertNil(refused)
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(model.items.map(\.id), ["a"])
    }

    func testARuleChangedSinceTheListLoadedIsSaidInTheServersWords() async {
        let model = await model()
        MockURLProtocol.requestHandler = { _ in self.list([self.post("a")]) }
        await model.load()
        MockURLProtocol.requestHandler = { _ in self.refusal(403, "FORBIDDEN", "Deleted posts cannot be restored in this app") }
        let refused = await model.restore(model.items[0])
        XCTAssertNil(refused)
        XCTAssertEqual(model.items.map(\.id), ["a"])
        XCTAssertEqual(model.errorMessage, "Deleted posts cannot be restored in this app")
    }

    func testAListReadBeforeTheRestoreFinishedDoesNotBringThePostBack() async {
        let model = await model()
        MockURLProtocol.requestHandler = { _ in self.list([self.post("a"), self.post("b")]) }
        await model.load()
        let item = model.items[0]

        // A refresh starts while the restore is being answered; Social read
        // the list while "a" was still deleted, and it arrives afterwards.
        var refresh: Task<Void, Never>?
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "POST" {
                DispatchQueue.main.sync { refresh = Task { await model.load() } }
                return TestFixtures.envelopedResponse(json: self.post("a", deletedDaysAgo: nil))
            }
            return self.list([self.post("a"), self.post("b")])
        }
        let back = await model.restore(item)
        await refresh?.value
        XCTAssertEqual(back?.id, "a")
        XCTAssertEqual(model.items.map(\.id), ["b"], "the restored post stays out of the stale list")

        // Deleted again later: a list asked for after the restore is believed.
        MockURLProtocol.requestHandler = { _ in self.list([self.post("a", deletedDaysAgo: 0), self.post("b")]) }
        await model.load()
        XCTAssertEqual(model.items.map(\.id), ["a", "b"])
    }

    func testAnotherPersonSigningInStartsFromNothing() async {
        let model = await model()
        MockURLProtocol.requestHandler = { _ in self.list([self.post("a")], by: "team") }
        await model.load()
        XCTAssertEqual(model.items.count, 1)

        let (app, _) = createTestClient()
        model.attach(social: SocialService(app: app), currentUserId: "someone-else")
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.hasLoaded)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.canRestore)

        // The same person attaching again (the screen reopened) keeps the list.
        MockURLProtocol.requestHandler = { _ in self.list([self.post("z")]) }
        await model.load()
        model.attach(social: SocialService(app: app), currentUserId: "someone-else")
        XCTAssertEqual(model.items.map(\.id), ["z"])
    }
}
