import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleSocial

/// Hiding a post, listing the hidden posts and showing one again, against
/// the JSON ScaleMule Social sends (scalemule-social `handlers/lifecycle.rs`,
/// `models.rs`: `HidePostResponse`, `HiddenPostsResponse`, `PostResponse`).
final class SocialHiddenPostsTests: XCTestCase {
    private let postId = "019b0000-0000-7000-8000-000000000001"

    /// One entry of `GET /posts/hidden`: the post's own fields with
    /// `hidden_at` beside them (and no end date: a hidden post has none).
    static let hiddenPostJSON = """
    {
        "id": "019b0000-0000-7000-8000-000000000001",
        "user_id": "019b0000-0000-7000-8000-0000000000aa",
        "content": "Скрий ме 藏起来 🙈",
        "media_urls": null,
        "media_ids": ["019b0000-0000-7000-8000-0000000000ff"],
        "visibility": "public",
        "metadata": {"kind": "photo", "author_name": "Sam", "width": 1080, "height": 1920},
        "likes_count": 1,
        "liked_by_me": false,
        "viewer_follows_author": false,
        "comments_count": 1,
        "shares_count": 0,
        "created_at": "2026-11-20T18:00:00Z",
        "hidden_at": "2026-11-25T08:00:00Z"
    }
    """

    private func signedIn() async -> SocialService {
        let (app, _) = createTestClient()
        try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600)))
        return SocialService(app: app)
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    // MARK: Hide

    func testHidePostsToTheHidePathAndSaysWhen() async {
        let social = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/social/posts/\(self.postId)/hide")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sess_123")
            return TestFixtures.envelopedResponse(json: #"{"hidden": true, "hidden_at": "2026-11-25T08:00:00Z"}"#)
        }
        let hiding = assertApiSuccess(await social.hidePost(id: postId))
        XCTAssertEqual(hiding?.hidden, true)
        XCTAssertEqual(hiding?.hiddenAt, date("2026-11-25T08:00:00Z"))
    }

    func testAHideAnswerWithFractionsOrWithoutADateStillReads() throws {
        let fractions = try JSONDecoder().decode(PostHiding.self, from: Data(#"{"hidden": true, "hidden_at": "2026-11-25T08:00:00.123456Z"}"#.utf8))
        XCTAssertEqual(fractions.hidden, true)
        XCTAssertNotNil(fractions.hiddenAt)
        let bare = try JSONDecoder().decode(PostHiding.self, from: Data("{}".utf8))
        XCTAssertEqual(bare.hidden, true)
        XCTAssertNil(bare.hiddenAt)
    }

    func testAnAppWithoutHidingSaysSoInWordsForPeople() async {
        let social = await signedIn()
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 403, json: #"{"success": false, "error": {"code": "FORBIDDEN", "message": "Hiding posts is not available in this app. You can delete the post instead."}}"#)
        }
        let error = assertApiFailure(await social.hidePost(id: postId), code: .forbidden)
        XCTAssertEqual(error?.userFacingMessage, "Hiding posts is not available in this app. You can delete the post instead.")
    }

    func testHidingSomeoneElsesPostIsNotFound() async {
        let social = await signedIn()
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 404, json: #"{"success": false, "error": {"code": "NOT_FOUND", "message": "Post not found"}}"#)
        }
        let error = assertApiFailure(await social.hidePost(id: postId), code: .notFound)
        XCTAssertEqual(error?.statusCode, 404)
    }

    // MARK: Hidden posts

    func testHiddenPostsAsksForAPageAndReadsEachPostWithItsDate() async {
        let social = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/social/posts/hidden")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(items.first { $0.name == "page" }?.value, "2")
            XCTAssertEqual(items.first { $0.name == "per_page" }?.value, "100", "capped as the server caps it")
            XCTAssertNil(items.first { $0.name == "user_id" }, "your own: the server knows who is asking")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sess_123")
            return TestFixtures.envelopedResponse(json: "{\"posts\": [\(Self.hiddenPostJSON)]}")
        }
        let page = assertApiSuccess(await social.hiddenPosts(page: 2, perPage: 500))
        XCTAssertEqual(page?.posts.count, 1)
        let hidden = page?.posts.first
        XCTAssertEqual(hidden?.id, postId)
        XCTAssertEqual(hidden?.post.content, "Скрий ме 藏起来 🙈")
        XCTAssertEqual(hidden?.post.mediaIds, ["019b0000-0000-7000-8000-0000000000ff"])
        XCTAssertEqual(hidden?.post.metadataString("kind"), "photo")
        XCTAssertEqual(hidden?.post.likesCount, 1)
        XCTAssertEqual(hidden?.post.commentsCount, 1)
        XCTAssertEqual(hidden?.hiddenAt, date("2026-11-25T08:00:00Z"))
    }

    func testNothingHiddenIsAnEmptyPage() async {
        let social = await signedIn()
        MockURLProtocol.requestHandler = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(items.first { $0.name == "page" }?.value, "1")
            XCTAssertEqual(items.first { $0.name == "per_page" }?.value, "30")
            return TestFixtures.envelopedResponse(json: #"{"posts": []}"#)
        }
        let page = assertApiSuccess(await social.hiddenPosts())
        XCTAssertEqual(page?.posts.isEmpty, true)
    }

    func testAHiddenPostWithoutADateStillReads() throws {
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.hiddenPostJSON.utf8)) as? [String: Any])
        fields["hidden_at"] = NSNull()
        let hidden = try JSONDecoder().decode(HiddenPost.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertEqual(hidden.id, postId)
        XCTAssertNil(hidden.hiddenAt)
    }

    // MARK: Unhide

    func testUnhidePostsToTheUnhidePathAndReturnsThePost() async {
        let social = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/social/posts/\(self.postId)/unhide")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sess_123")
            return TestFixtures.envelopedResponse(json: SocialServiceTests.postJSON)
        }
        let post = assertApiSuccess(await social.unhidePost(id: postId))
        XCTAssertEqual(post?.id, postId)
        XCTAssertEqual(post?.mediaIds, ["019b0000-0000-7000-8000-0000000000ff"])
        XCTAssertEqual(post?.likesCount, 2, "its likes came back with it")
    }

    func testUnhideRefusalsKeepTheServersWords() async {
        let social = await signedIn()
        // Taken down while it was hidden.
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 403, json: #"{"success": false, "error": {"code": "FORBIDDEN", "message": "This post was removed and cannot be shown again"}}"#)
        }
        let removed = assertApiFailure(await social.unhidePost(id: postId), code: .forbidden)
        XCTAssertEqual(removed?.userFacingMessage, "This post was removed and cannot be shown again")
        // Deleted, or not yours.
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 404, json: #"{"success": false, "error": {"code": "NOT_FOUND", "message": "Post not found"}}"#)
        }
        _ = assertApiFailure(await social.unhidePost(id: postId), code: .notFound)
    }
}
