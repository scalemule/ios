import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleSocial

/// Deleting a post, listing the deleted posts still kept and restoring one,
/// against the JSON ScaleMule Social sends (scalemule-social
/// `handlers/lifecycle.rs`, `models.rs`: `DeletePostResponse`,
/// `DeletedPostsResponse`, `PostResponse`).
final class SocialDeletedPostsTests: XCTestCase {
    private let postId = "019b0000-0000-7000-8000-000000000001"

    /// One entry of `GET /posts/deleted`: the post's own fields with
    /// `deleted_at` and `restorable_until` beside them.
    static let deletedPostJSON = """
    {
        "id": "019b0000-0000-7000-8000-000000000001",
        "user_id": "019b0000-0000-7000-8000-0000000000aa",
        "content": "Изтрий ме 删除我 🗑️",
        "media_urls": null,
        "media_ids": ["019b0000-0000-7000-8000-0000000000ff"],
        "visibility": "public",
        "metadata": {"kind": "video", "author_name": "Sam", "width": 1080, "height": 1920, "duration": 8},
        "likes_count": 1,
        "liked_by_me": false,
        "viewer_follows_author": false,
        "comments_count": 1,
        "shares_count": 0,
        "created_at": "2026-11-20T18:00:00Z",
        "deleted_at": "2026-11-25T08:00:00Z",
        "restorable_until": "2026-12-25T08:00:00Z"
    }
    """

    private func signedIn() async -> SocialService {
        let (app, _) = createTestClient()
        try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600)))
        return SocialService(app: app)
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    // MARK: Delete

    func testDeleteSaysUntilWhenThePostCanBeRestored() async {
        let social = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/v1/social/posts/abc")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sess_123")
            return TestFixtures.envelopedResponse(json: #"{"deleted": true, "restorable_until": "2026-12-25T08:00:00Z", "restorable_by": "author"}"#)
        }
        let deletion = assertApiSuccess(await social.deletePost(id: "abc"))
        XCTAssertEqual(deletion?.deleted, true)
        XCTAssertEqual(deletion?.restorableUntil, date("2026-12-25T08:00:00Z"))
        XCTAssertEqual(deletion?.restorableBy, .author)

        let justDeleted = date("2026-11-25T08:00:02Z")
        XCTAssertEqual(deletion?.daysToRestore(now: justDeleted), 30, "30 days, said two seconds later")
        XCTAssertEqual(deletion?.daysToRestore(now: date("2026-12-24T09:00:00Z")), 1, "the last part of a day is a day")
        XCTAssertNil(deletion?.daysToRestore(now: date("2026-12-25T08:00:00Z")), "the date has passed")
        XCTAssertEqual(deletion?.canBeRestoredByAuthor(now: justDeleted), true)
    }

    func testDeleteReadsADateWithFractionsOfASecond() async {
        let social = await signedIn()
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.envelopedResponse(json: #"{"deleted": true, "restorable_until": "2026-12-02T08:00:00.123456Z", "restorable_by": "author"}"#)
        }
        let deletion = assertApiSuccess(await social.deletePost(id: "abc"))
        XCTAssertEqual(deletion?.daysToRestore(now: date("2026-11-25T08:00:01Z")), 7, "an app that keeps posts a week")
    }

    func testAnAppThatKeepsNothingDeletesForGood() async {
        let social = await signedIn()
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.envelopedResponse(json: #"{"deleted": true, "restorable_until": null, "restorable_by": "nobody"}"#)
        }
        let deletion = assertApiSuccess(await social.deletePost(id: "abc"))
        XCTAssertEqual(deletion?.deleted, true)
        XCTAssertNil(deletion?.restorableUntil)
        XCTAssertEqual(deletion?.restorableBy, .nobody)
        XCTAssertNil(deletion?.daysToRestore())
        XCTAssertEqual(deletion?.canBeRestoredByAuthor(), false)
    }

    func testOnlyTheTeamRestoresWhereTheAppSaysSo() async {
        let social = await signedIn()
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.envelopedResponse(json: #"{"deleted": true, "restorable_until": "2026-12-25T08:00:00Z", "restorable_by": "team"}"#)
        }
        let deletion = assertApiSuccess(await social.deletePost(id: "abc"))
        XCTAssertEqual(deletion?.restorableBy, .team)
        XCTAssertNotNil(deletion?.restorableUntil)
        XCTAssertNil(deletion?.daysToRestore(now: date("2026-11-25T08:00:00Z")), "the author is not offered a restore they cannot do")
    }

    func testDeleteAnswersFromBeforeRestoreStillRead() async {
        let social = await signedIn()
        // An older Social said only that it was deleted, or nothing at all.
        for body in [#"{"success": true, "data": {"deleted": true}}"#, #"{"success": true, "data": null}"#] {
            MockURLProtocol.requestHandler = { _ in TestFixtures.mockResponse(statusCode: 200, json: body) }
            let deletion = assertApiSuccess(await social.deletePost(id: "abc"))
            XCTAssertEqual(deletion?.deleted, true)
            XCTAssertNil(deletion?.restorableUntil)
            XCTAssertEqual(deletion?.restorableBy, .nobody)
        }
        // A rule this SDK version does not know is never offered as a restore.
        let unknown = try? JSONDecoder().decode(PostDeletion.self, from: Data(#"{"deleted": true, "restorable_until": "2026-12-25T08:00:00Z", "restorable_by": "moderators"}"#.utf8))
        XCTAssertEqual(unknown?.restorableBy, .nobody)
    }

    func testDeletingSomeoneElsesPostIsRefusedInWordsForPeople() async {
        let social = await signedIn()
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 404, json: #"{"success": false, "error": {"code": "NOT_FOUND", "message": "Post not found or you don't have permission to delete it"}}"#)
        }
        let error = assertApiFailure(await social.deletePost(id: "abc"), code: .notFound)
        XCTAssertEqual(error?.userFacingMessage, "Post not found or you don't have permission to delete it")
    }

    // MARK: Deleted posts

    func testDeletedPostsAsksForAPageAndReadsEachPostWithItsDates() async {
        let social = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/social/posts/deleted")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(items.first { $0.name == "page" }?.value, "2")
            XCTAssertEqual(items.first { $0.name == "per_page" }?.value, "100", "capped as the server caps it")
            XCTAssertNil(items.first { $0.name == "user_id" }, "your own: the server knows who is asking")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sess_123")
            return TestFixtures.envelopedResponse(json: "{\"posts\": [\(Self.deletedPostJSON)], \"restorable_by\": \"author\"}")
        }
        let page = assertApiSuccess(await social.deletedPosts(page: 2, perPage: 500))
        XCTAssertEqual(page?.restorableBy, .author)
        XCTAssertEqual(page?.posts.count, 1)
        let deleted = page?.posts.first
        XCTAssertEqual(deleted?.id, postId)
        XCTAssertEqual(deleted?.post.content, "Изтрий ме 删除我 🗑️")
        XCTAssertEqual(deleted?.post.mediaIds, ["019b0000-0000-7000-8000-0000000000ff"], "the media is still named: it was not deleted")
        XCTAssertEqual(deleted?.post.metadataString("kind"), "video")
        XCTAssertEqual(deleted?.post.likesCount, 1)
        XCTAssertEqual(deleted?.post.commentsCount, 1)
        XCTAssertEqual(deleted?.deletedAt, date("2026-11-25T08:00:00Z"))
        XCTAssertEqual(deleted?.restorableUntil, date("2026-12-25T08:00:00Z"))
        XCTAssertEqual(deleted?.daysLeft(now: date("2026-11-25T08:00:00Z")), 30)
        XCTAssertEqual(deleted?.daysLeft(now: date("2026-11-26T20:00:00Z")), 29, "28 and a half days read as 29")
        XCTAssertEqual(deleted?.daysLeft(now: date("2026-12-25T07:59:00Z")), 1)
        XCTAssertEqual(deleted?.daysLeft(now: date("2026-12-26T00:00:00Z")), 0)
    }

    func testNothingDeletedIsAnEmptyPage() async {
        let social = await signedIn()
        MockURLProtocol.requestHandler = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(items.first { $0.name == "page" }?.value, "1")
            XCTAssertEqual(items.first { $0.name == "per_page" }?.value, "30")
            return TestFixtures.envelopedResponse(json: #"{"posts": [], "restorable_by": "nobody"}"#)
        }
        let page = assertApiSuccess(await social.deletedPosts())
        XCTAssertEqual(page?.posts.isEmpty, true)
        XCTAssertEqual(page?.restorableBy, .nobody)
    }

    func testADeletedPostWithoutDatesStillReads() throws {
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.deletedPostJSON.utf8)) as? [String: Any])
        fields["deleted_at"] = nil
        fields["restorable_until"] = NSNull()
        let deleted = try JSONDecoder().decode(DeletedPost.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertEqual(deleted.id, postId)
        XCTAssertNil(deleted.deletedAt)
        XCTAssertNil(deleted.restorableUntil)
        XCTAssertEqual(deleted.daysLeft(), 0)
    }

    // MARK: Restore

    func testRestorePostsToTheRestorePathAndReturnsThePost() async {
        let social = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/social/posts/\(self.postId)/restore")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sess_123")
            return TestFixtures.envelopedResponse(json: SocialServiceTests.postJSON)
        }
        let post = assertApiSuccess(await social.restorePost(id: postId))
        XCTAssertEqual(post?.id, postId)
        XCTAssertEqual(post?.mediaIds, ["019b0000-0000-7000-8000-0000000000ff"])
    }

    func testRestoreRefusalsKeepTheServersWords() async {
        let social = await signedIn()
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 410, json: #"{"success": false, "error": {"code": "RESTORE_WINDOW_EXPIRED", "message": "This post was deleted too long ago to be restored"}}"#)
        }
        let expired = assertApiFailure(await social.restorePost(id: postId))
        XCTAssertEqual(expired?.isRestoreWindowExpired, true)
        XCTAssertEqual(expired?.statusCode, 410)
        XCTAssertEqual(expired?.userFacingMessage, "This post was deleted too long ago to be restored")

        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 403, json: #"{"success": false, "error": {"code": "FORBIDDEN", "message": "Only the app's team can restore a deleted post in this app"}}"#)
        }
        let refused = assertApiFailure(await social.restorePost(id: postId), code: .forbidden)
        XCTAssertEqual(refused?.isRestoreWindowExpired, false)
        XCTAssertEqual(refused?.userFacingMessage, "Only the app's team can restore a deleted post in this app")

        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 500, json: #"{"success": false, "error": {"code": "INTERNAL_ERROR", "message": "An internal error occurred"}}"#)
        }
        let broken = assertApiFailure(await social.restorePost(id: postId))
        XCTAssertEqual(broken?.userFacingMessage, "Something went wrong on our side. Please try again in a minute.")
    }
}
