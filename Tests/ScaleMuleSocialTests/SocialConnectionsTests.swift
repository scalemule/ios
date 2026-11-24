import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleSocial

final class SocialConnectionsTests: XCTestCase {
    private let me = "019b0000-0000-7000-8000-0000000000aa"
    private let them = "019b0000-0000-7000-8000-0000000000bb"
    private let postId = "019b0000-0000-7000-8000-000000000001"

    private func service() -> SocialService {
        let (app, _) = createTestClient()
        return SocialService(app: app)
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testFollowingFeedAsksForTheFollowingScopeAndReadsTheFollowFlag() async {
        let social = service()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/social/feed")
            XCTAssertEqual(self.query(request)["scope"], "following")
            let post = SocialServiceTests.postJSON.replacingOccurrences(of: "\"likes_count\": 2,", with: "\"likes_count\": 2, \"viewer_follows_author\": true,")
            return TestFixtures.envelopedResponse(json: "{\"posts\": [\(post)]}")
        }
        let posts = assertApiSuccess(await social.feed(scope: .following))
        XCTAssertEqual(posts?.first?.viewerFollowsAuthor, true)

        MockURLProtocol.requestHandler = { request in
            XCTAssertNil(self.query(request)["scope"], "everyone's feed is the server's default")
            return TestFixtures.envelopedResponse(json: "{\"posts\": [\(SocialServiceTests.postJSON)]}")
        }
        let everyone = assertApiSuccess(await social.feed())
        XCTAssertNil(everyone?.first?.viewerFollowsAuthor, "an older server does not say")
    }

    func testFollowAndUnfollow() async {
        let social = service()
        var seen: [String] = []
        MockURLProtocol.requestHandler = { request in
            seen.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            return TestFixtures.envelopedResponse(json: "null")
        }
        _ = assertApiSuccess(await social.follow(userId: them))
        _ = assertApiSuccess(await social.unfollow(userId: them))
        XCTAssertEqual(seen, ["POST /v1/social/users/\(them)/follow", "DELETE /v1/social/users/\(them)/follow"])
    }

    func testFollowStatusReadsCountsWhenTheServerSendsThem() async {
        let social = service()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/social/users/\(self.them)/follow-status")
            return TestFixtures.envelopedResponse(json: "{\"is_following\": true, \"is_followed_by\": false, \"followers_count\": 12, \"following_count\": 3}")
        }
        let status = assertApiSuccess(await social.followStatus(userId: them))
        XCTAssertEqual(status, FollowStatus(isFollowing: true, isFollowedBy: false, followersCount: 12, followingCount: 3))

        MockURLProtocol.requestHandler = { _ in
            TestFixtures.envelopedResponse(json: "{\"is_following\": false, \"is_followed_by\": true}")
        }
        let older = assertApiSuccess(await social.followStatus(userId: them))
        XCTAssertEqual(older?.isFollowedBy, true)
        XCTAssertNil(older?.followersCount)
    }

    func testFollowersAndFollowingLists() async {
        let social = service()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(self.query(request)["page"], "2")
            XCTAssertEqual(self.query(request)["per_page"], "100")
            let key = request.url!.path.hasSuffix("/followers") ? "followers" : "following"
            return TestFixtures.envelopedResponse(json: "{\"\(key)\": [{\"user_id\": \"\(self.me)\", \"followed_at\": \"2026-11-24T10:00:00Z\"}]}")
        }
        let followers = assertApiSuccess(await social.followers(userId: them, page: 2, perPage: 400))
        XCTAssertEqual(followers?.map(\.userId), [me])
        let following = assertApiSuccess(await social.following(userId: them, page: 2, perPage: 400))
        XCTAssertEqual(following?.first?.id, me)
    }

    func testCommentsListAddAndDelete() async {
        let social = service()
        let comment = """
        {"id": "c1", "post_id": "\(postId)", "user_id": "\(them)", "parent_comment_id": null,
         "content": "it&#x27;s great &amp; loud 🎉", "likes_count": 0, "created_at": "2026-11-24T10:00:00.5Z"}
        """
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/social/posts/\(self.postId)/comments")
            return TestFixtures.envelopedResponse(json: "{\"comments\": [\(comment)]}")
        }
        let list = assertApiSuccess(await social.comments(postId: postId))
        XCTAssertEqual(list?.first?.content, "it's great & loud 🎉", "people see the text, not its escaped form")
        XCTAssertNotNil(list?.first?.createdDate)
        XCTAssertNil(list?.first?.parentCommentId)

        var calls = 0
        MockURLProtocol.requestHandler = { request in
            calls += 1
            XCTAssertEqual(request.httpMethod, "POST")
            let body = self.bodyJSON(request)
            XCTAssertEqual(body?["content"] as? String, "Nice one")
            XCTAssertEqual(body?["parent_comment_id"] as? String, "c1")
            return TestFixtures.envelopedResponse(json: comment)
        }
        let added = assertApiSuccess(await social.addComment(postId: postId, content: "Nice one", replyingTo: "c1"))
        XCTAssertEqual(added?.id, "c1")
        XCTAssertEqual(calls, 1)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/v1/social/posts/\(self.postId)/comments/c1")
            return TestFixtures.envelopedResponse(json: "null")
        }
        _ = assertApiSuccess(await social.deleteComment(postId: postId, commentId: "c1"))
    }

    func testActivityReadsMetadataAsTextOrObject() async {
        let social = service()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/social/activity")
            XCTAssertEqual(self.query(request)["limit"], "200")
            XCTAssertEqual(self.query(request)["unread_only"], "true")
            return TestFixtures.envelopedResponse(json: """
            {"activities": [
              {"id": "a1", "activity_type": "comment", "actor_user_id": "\(self.them)", "target_type": "post", "target_id": "\(self.postId)",
               "metadata": "{\\"comment_id\\": \\"c1\\", \\"text\\": \\"so good\\"}", "is_read": false, "created_at": "2026-11-24T10:00:00Z"},
              {"id": "a2", "activity_type": "reply", "actor_user_id": "\(self.them)", "target_type": "post", "target_id": "\(self.postId)",
               "metadata": {"comment_id": "c2", "text": "agreed"}, "is_read": true, "created_at": "2026-11-24T09:00:00Z"},
              {"id": "a3", "activity_type": "follow", "actor_user_id": "\(self.them)", "target_type": null, "target_id": null,
               "metadata": null, "is_read": true, "created_at": "2026-11-24T08:00:00Z"},
              {"id": "a4", "activity_type": "gift", "actor_user_id": "\(self.them)", "is_read": true, "created_at": "2026-11-24T07:00:00Z"}
            ]}
            """)
        }
        let items = assertApiSuccess(await social.activity(limit: 999, unreadOnly: true)) ?? []
        XCTAssertEqual(items.map(\.kind), [.comment, .reply, .follow, .other])
        XCTAssertEqual(items[0].commentText, "so good")
        XCTAssertEqual(items[0].commentId, "c1")
        XCTAssertEqual(items[0].postId, postId)
        XCTAssertFalse(items[0].isRead)
        XCTAssertEqual(items[1].commentText, "agreed")
        XCTAssertNil(items[2].postId)
        XCTAssertNil(items[2].commentText)
    }

    func testUnreadCountAndMarkingRead() async {
        let social = service()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/social/activity/unread-count")
            return TestFixtures.envelopedResponse(json: "{\"unread\": 7}")
        }
        let unread = assertApiSuccess(await social.unreadActivityCount())
        XCTAssertEqual(unread, 7)

        var seen: [String] = []
        MockURLProtocol.requestHandler = { request in
            seen.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            return TestFixtures.envelopedResponse(json: "null")
        }
        _ = assertApiSuccess(await social.markActivityRead(id: "a1"))
        _ = assertApiSuccess(await social.markAllActivityRead())
        XCTAssertEqual(seen, ["PATCH /v1/social/activity/a1/read", "PATCH /v1/social/activity/read-all"])
    }
}
