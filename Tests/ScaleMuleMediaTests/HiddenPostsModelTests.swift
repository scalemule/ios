import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleMediaPosts
@testable import ScaleMuleSocial

/// The "Hidden posts" list against a mocked Social that answers as
/// scalemule-social does (`GET /posts/hidden`, `POST /posts/{id}/unhide`,
/// `DELETE /posts/{id}`).
@MainActor
final class HiddenPostsModelTests: XCTestCase {
    private let me = "019b0000-0000-7000-8000-0000000000aa"

    private func model(pageSize: Int = 30) async -> HiddenPostsModel {
        let (app, _) = createTestClient()
        try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600)))
        let model = HiddenPostsModel(pageSize: pageSize)
        model.attach(social: SocialService(app: app), currentUserId: me)
        return model
    }

    private func stamp(daysFromNow days: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(days * 86_400))
    }

    /// A post as Social lists it; `hiddenDaysAgo` nil is the post itself (an unhide's answer).
    private func post(_ id: String, kind: String = "photo", hiddenDaysAgo: Double? = 1, media: Bool = true) -> String {
        var fields = [
            #""id":"\#(id)""#, #""user_id":"\#(me)""#, #""content":"Oakland, CA""#, #""media_urls":null"#,
            #""visibility":"public""#, #""likes_count":2"#, #""liked_by_me":false"#, #""viewer_follows_author":false"#,
            #""comments_count":1"#, #""shares_count":0"#,
            #""metadata":{"kind":"\#(kind)","author_name":"Sam","width":1080,"height":1920}"#,
            #""created_at":"\#(stamp(daysFromNow: -10))""#,
        ]
        if media { fields.append(#""media_ids":["m-\#(id)"]"#) }
        if let hiddenDaysAgo { fields.append(#""hidden_at":"\#(stamp(daysFromNow: -hiddenDaysAgo))""#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private func list(_ posts: [String]) -> (HTTPURLResponse, Data) {
        TestFixtures.envelopedResponse(json: #"{"posts":[\#(posts.joined(separator: ","))]}"#)
    }

    private func deleted(by restorer: String, days: Double? = 730) -> (HTTPURLResponse, Data) {
        let until = days.map { #""\#(stamp(daysFromNow: $0))""# } ?? "null"
        return TestFixtures.envelopedResponse(json: #"{"deleted":true,"restorable_until":\#(until),"restorable_by":"\#(restorer)"}"#)
    }

    private func page(of request: URLRequest) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
    }

    private func refusal(_ status: Int, _ code: String, _ message: String) -> (HTTPURLResponse, Data) {
        TestFixtures.mockResponse(statusCode: status, json: #"{"success":false,"error":{"code":"\#(code)","message":"\#(message)"}}"#)
    }

    // MARK: Loading

    func testListsHiddenPostsWithWhenEachWasHidden() async {
        let model = await model()
        XCTAssertFalse(model.hasLoaded)
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/social/posts/hidden")
            XCTAssertEqual(self.page(of: request), "1")
            return self.list([self.post("a", hiddenDaysAgo: 0.5), self.post("clip", kind: "video", hiddenDaysAgo: 400), self.post("words", media: false)])
        }
        await model.load()
        XCTAssertTrue(model.hasLoaded)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.items.map(\.id), ["a", "clip"], "a post without a photo or video has no row")
        XCTAssertEqual(model.items[0].post.mediaId, "m-a")
        XCTAssertTrue(model.items[0].post.isMine)
        XCTAssertTrue(model.items[1].post.isVideo)
        let halfADay = Date().timeIntervalSince(model.items[0].hiddenAt ?? .distantPast)
        XCTAssertEqual(halfADay, 43_200, accuracy: 5)
        XCTAssertNotNil(model.items[1].hiddenAt, "hidden more than a year ago and still there: no end date")
        XCTAssertFalse(model.hasMore)
    }

    func testNothingHiddenIsAnEmptyLoadedList() async {
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
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        await model.load()
        XCTAssertEqual(model.items.map(\.id), ["a"])
        XCTAssertEqual(model.errorMessage, "You seem to be offline. Check your connection and try again.")
        MockURLProtocol.requestHandler = { _ in self.list([self.post("a")]) }
        await model.load()
        XCTAssertNil(model.errorMessage)
    }

    func testPagesOnDemandWithoutRepeats() async {
        let model = await model(pageSize: 2)
        var asked: [String] = []
        MockURLProtocol.requestHandler = { request in
            let page = self.page(of: request) ?? ""
            asked.append(page)
            // "b" moved onto the second page as well (something was unhidden in between).
            return page == "1" ? self.list([self.post("a"), self.post("b")]) : self.list([self.post("b"), self.post("c")])
        }
        await model.load()
        XCTAssertTrue(model.hasMore)
        await model.loadMore()
        XCTAssertEqual(asked, ["1", "2"])
        XCTAssertEqual(model.items.map(\.id), ["a", "b", "c"])
        MockURLProtocol.requestHandler = { _ in self.list([]) }
        await model.loadMore()
        XCTAssertFalse(model.hasMore)
        await model.loadMore()
        XCTAssertEqual(model.items.count, 3)
    }

    // MARK: Unhide

    func testUnhideTakesThePostOutAtOnceAndHandsItToTheFeed() async {
        let model = await model()
        MockURLProtocol.requestHandler = { _ in self.list([self.post("a"), self.post("b"), self.post("c")]) }
        await model.load()

        var shown: [MediaPost] = []
        model.onUnhidden = { shown.append($0) }
        var whileAsking: [String] = []
        var busyWhileAsking = false
        var requests: [String] = []
        MockURLProtocol.requestHandler = { request in
            requests.append("\(request.httpMethod ?? "") \(request.url!.path)")
            DispatchQueue.main.sync {
                whileAsking = model.items.map(\.id)
                busyWhileAsking = model.working.contains("b")
            }
            return TestFixtures.envelopedResponse(json: self.post("b", hiddenDaysAgo: nil))
        }
        let back = await model.unhide(model.items[1])
        XCTAssertEqual(requests, ["POST /v1/social/posts/b/unhide"])
        XCTAssertEqual(whileAsking, ["a", "c"], "gone before the server answered")
        XCTAssertTrue(busyWhileAsking)
        XCTAssertEqual(model.items.map(\.id), ["a", "c"])
        XCTAssertTrue(model.working.isEmpty)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(back?.id, "b")
        XCTAssertEqual(back?.mediaId, "m-b")
        XCTAssertEqual(back?.likes, 2, "its likes came back with it")
        XCTAssertEqual(shown.map(\.id), ["b"])
    }

    func testARefusedUnhidePutsThePostBackWhereItWas() async {
        let model = await model()
        MockURLProtocol.requestHandler = { _ in self.list([self.post("a"), self.post("b"), self.post("c")]) }
        await model.load()
        var shown = 0
        model.onUnhidden = { _ in shown += 1 }

        MockURLProtocol.requestHandler = { _ in self.refusal(500, "INTERNAL_ERROR", "An internal error occurred") }
        let failed = await model.unhide(model.items[1])
        XCTAssertNil(failed)
        XCTAssertEqual(model.items.map(\.id), ["a", "b", "c"], "back in its place")
        XCTAssertEqual(model.errorMessage, "Something went wrong on our side. Please try again in a minute.")
        XCTAssertTrue(model.working.isEmpty)
        XCTAssertEqual(shown, 0)

        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        let offline = await model.unhide(model.items[2])
        XCTAssertNil(offline)
        XCTAssertEqual(model.items.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(model.errorMessage, "You seem to be offline. Check your connection and try again.")

        // Trying again works and clears the message.
        MockURLProtocol.requestHandler = { _ in TestFixtures.envelopedResponse(json: self.post("c", hiddenDaysAgo: nil)) }
        let worked = await model.unhide(model.items[2])
        XCTAssertEqual(worked?.id, "c")
        XCTAssertEqual(model.items.map(\.id), ["a", "b"])
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(shown, 1)
    }

    func testAPostThatCanNoLongerBeShownLeavesTheList() async {
        let model = await model()
        MockURLProtocol.requestHandler = { _ in self.list([self.post("a"), self.post("taken"), self.post("gone")]) }
        await model.load()

        // Taken down while it was hidden: Social's sentence, and no row to tap again.
        MockURLProtocol.requestHandler = { _ in self.refusal(403, "FORBIDDEN", "This post was removed and cannot be shown again") }
        let taken = await model.unhide(model.items[1])
        XCTAssertNil(taken)
        XCTAssertEqual(model.items.map(\.id), ["a", "gone"])
        XCTAssertEqual(model.errorMessage, "This post was removed and cannot be shown again")

        // Deleted on another phone between the list and the tap.
        MockURLProtocol.requestHandler = { _ in self.refusal(404, "NOT_FOUND", "Post not found") }
        let gone = await model.unhide(model.items[1])
        XCTAssertNil(gone)
        XCTAssertEqual(model.items.map(\.id), ["a"])
        XCTAssertEqual(model.errorMessage, "This post isn't among your hidden posts any more.")
    }

    // MARK: Delete

    func testDeleteTakesThePostOutAndSaysWhetherItCanComeBack() async {
        let model = await model()
        MockURLProtocol.requestHandler = { _ in self.list([self.post("a"), self.post("b"), self.post("c")]) }
        await model.load()
        var shown = 0
        model.onUnhidden = { _ in shown += 1 }

        // An app where delete is final for the person (only its team restores).
        var requests: [String] = []
        var whileAsking: [String] = []
        MockURLProtocol.requestHandler = { request in
            requests.append("\(request.httpMethod ?? "") \(request.url!.path)")
            DispatchQueue.main.sync { whileAsking = model.items.map(\.id) }
            return self.deleted(by: "team")
        }
        let final = await model.delete(model.items[0])
        XCTAssertEqual(requests, ["DELETE /v1/social/posts/a"], "only the post, never its photo or video")
        XCTAssertEqual(whileAsking, ["b", "c"], "gone before the server answered")
        XCTAssertEqual(model.items.map(\.id), ["b", "c"])
        XCTAssertEqual(final?.restorableBy, .team)
        XCTAssertEqual(final?.canBeRestoredByAuthor(), false)
        XCTAssertNil(final?.daysToRestore(), "no way back is promised")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(shown, 0, "a deleted post is not handed to the feed")

        // An app whose authors restore.
        MockURLProtocol.requestHandler = { _ in self.deleted(by: "author", days: 30) }
        let kept = await model.delete(model.items[0])
        XCTAssertEqual(kept?.daysToRestore(), 30)
        XCTAssertEqual(model.items.map(\.id), ["c"])
    }

    func testARefusedDeletePutsThePostBackWhereItWas() async {
        let model = await model()
        MockURLProtocol.requestHandler = { _ in self.list([self.post("a"), self.post("b")]) }
        await model.load()

        MockURLProtocol.requestHandler = { _ in self.refusal(503, "SERVICE_UNAVAILABLE", "Try later") }
        let failed = await model.delete(model.items[0])
        XCTAssertNil(failed)
        XCTAssertEqual(model.items.map(\.id), ["a", "b"], "back in its place, so deleting again can work")
        XCTAssertEqual(model.errorMessage, "Something went wrong on our side. Please try again in a minute.")
        XCTAssertTrue(model.working.isEmpty)

        // Already gone (deleted on another phone): nothing to put back.
        MockURLProtocol.requestHandler = { _ in self.refusal(404, "NOT_FOUND", "Post not found or you don't have permission to delete it") }
        let gone = await model.delete(model.items[0])
        XCTAssertNil(gone)
        XCTAssertEqual(model.items.map(\.id), ["b"])
        XCTAssertEqual(model.errorMessage, "This post isn't among your hidden posts any more.")
    }

    // MARK: Races

    func testAListReadBeforeTheChangeFinishedDoesNotBringThePostBack() async {
        let model = await model()
        MockURLProtocol.requestHandler = { _ in self.list([self.post("a"), self.post("b"), self.post("c")]) }
        await model.load()

        // A refresh starts while the unhide is being answered; Social read
        // the list while "a" was still hidden, and it arrives afterwards.
        var refresh: Task<Void, Never>?
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "POST" {
                DispatchQueue.main.sync { refresh = Task { await model.load() } }
                return TestFixtures.envelopedResponse(json: self.post("a", hiddenDaysAgo: nil))
            }
            return self.list([self.post("a"), self.post("b"), self.post("c")])
        }
        let back = await model.unhide(model.items[0])
        await refresh?.value
        XCTAssertEqual(back?.id, "a")
        XCTAssertEqual(model.items.map(\.id), ["b", "c"], "the shown post stays out of the stale list")

        // The same for a delete.
        refresh = nil
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "DELETE" {
                DispatchQueue.main.sync { refresh = Task { await model.load() } }
                return self.deleted(by: "team")
            }
            return self.list([self.post("b"), self.post("c")])
        }
        let deletion = await model.delete(model.items[0])
        await refresh?.value
        XCTAssertNotNil(deletion)
        XCTAssertEqual(model.items.map(\.id), ["c"])

        // Hidden again later: a list asked for after that is believed.
        MockURLProtocol.requestHandler = { _ in self.list([self.post("a", hiddenDaysAgo: 0), self.post("c")]) }
        await model.load()
        XCTAssertEqual(model.items.map(\.id), ["a", "c"])
    }

    func testAPostBeingChangedIsNotAskedTwice() async {
        let model = await model()
        MockURLProtocol.requestHandler = { _ in self.list([self.post("a"), self.post("b")]) }
        await model.load()
        let item = model.items[0]
        var asked = 0
        var second: Task<PostDeletion?, Never>?
        MockURLProtocol.requestHandler = { _ in
            asked += 1
            // A second tap (Delete) while the unhide is on its way.
            DispatchQueue.main.sync { second = Task { await model.delete(item) } }
            return TestFixtures.envelopedResponse(json: self.post("a", hiddenDaysAgo: nil))
        }
        let back = await model.unhide(item)
        let deletion = await second?.value
        XCTAssertEqual(back?.id, "a")
        XCTAssertNil(deletion ?? nil)
        XCTAssertEqual(asked, 1, "the post that is showing again was not deleted")
    }

    func testAnotherPersonSigningInStartsFromNothing() async {
        let model = await model()
        MockURLProtocol.requestHandler = { _ in self.list([self.post("a")]) }
        await model.load()
        XCTAssertEqual(model.items.count, 1)

        let (app, _) = createTestClient()
        model.attach(social: SocialService(app: app), currentUserId: "someone-else")
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.hasLoaded)
        XCTAssertNil(model.errorMessage)

        // The same person attaching again (the screen reopened) keeps the list.
        MockURLProtocol.requestHandler = { _ in self.list([self.post("z")]) }
        await model.load()
        model.attach(social: SocialService(app: app), currentUserId: "someone-else")
        XCTAssertEqual(model.items.map(\.id), ["z"])
    }
}
