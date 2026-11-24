import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleMediaPosts
@testable import ScaleMuleProfiles
@testable import ScaleMuleSocial

/// Follow state, comments, the activity inbox and a person's page, against a
/// mocked Social.
@MainActor
final class SocialPeopleModelsTests: XCTestCase {
    private let me = "019b0000-0000-7000-8000-0000000000aa"
    private let them = "019b0000-0000-7000-8000-0000000000bb"
    private let postId = "019b0000-0000-7000-8000-000000000001"

    private func services() -> (SocialService, PublicProfiles) {
        let (app, _) = createTestClient()
        return (SocialService(app: app), PublicProfiles(app: app))
    }

    private func comment(_ id: String, by user: String, parent: String? = nil, text: String = "hello") -> String {
        """
        {"id": "\(id)", "post_id": "\(postId)", "user_id": "\(user)", "parent_comment_id": \(parent.map { "\"\($0)\"" } ?? "null"),
         "content": "\(text)", "likes_count": 0, "created_at": "2026-11-24T10:00:00Z"}
        """
    }

    private func post(_ id: String, by user: String, follows: Bool? = nil, comments: Int = 0) -> SocialPost {
        let flag = follows.map { ", \"viewer_follows_author\": \($0)" } ?? ""
        let json = """
        {"id": "\(id)", "user_id": "\(user)", "content": "x", "media_ids": ["m-\(id)"], "visibility": "public",
         "likes_count": 0, "comments_count": \(comments), "shares_count": 0, "created_at": "2026-11-24T10:00:00Z"\(flag)}
        """
        return try! JSONDecoder().decode(SocialPost.self, from: Data(json.utf8))
    }

    // MARK: Follow

    func testFollowShowsAtOnceAndGoesBackWhenTheServerRefuses() async {
        let (social, _) = services()
        let follows = FollowStore()
        follows.attach(social: social, currentUserId: me)
        follows.note(them, following: false)
        XCTAssertTrue(follows.canFollow(them))
        XCTAssertFalse(follows.canFollow(me), "never a Follow button on yourself")

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return TestFixtures.envelopedResponse(json: "null")
        }
        let followed = await follows.setFollowing(them, true)
        XCTAssertNil(followed)
        XCTAssertEqual(follows.isFollowing(them), true)

        follows.note(them, following: false)
        XCTAssertEqual(follows.isFollowing(them), true, "a feed page loaded before the tap does not undo it")

        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 500, json: "{\"success\": false, \"error\": {\"code\": \"INTERNAL_ERROR\", \"message\": \"no\"}}")
        }
        let refused = await follows.setFollowing(them, false)
        XCTAssertNotNil(refused)
        XCTAssertEqual(follows.isFollowing(them), true, "still following: the unfollow did not happen")
        XCTAssertTrue(follows.busy.isEmpty)
    }

    func testAlreadyFollowingAndAlreadyNotAreNotErrors() async {
        let (social, _) = services()
        let follows = FollowStore()
        follows.attach(social: social, currentUserId: me)
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 409, json: "{\"success\": false, \"error\": {\"code\": \"CONFLICT\", \"message\": \"already\"}}")
        }
        let again = await follows.setFollowing(them, true)
        XCTAssertNil(again)
        XCTAssertEqual(follows.isFollowing(them), true)
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 404, json: "{\"success\": false, \"error\": {\"code\": \"NOT_FOUND\", \"message\": \"none\"}}")
        }
        let gone = await follows.setFollowing(them, false)
        XCTAssertNil(gone)
        XCTAssertEqual(follows.isFollowing(them), false)
    }

    func testPostsTeachTheStoreAndSigningInAsSomeoneElseForgets() {
        let (social, _) = services()
        let follows = FollowStore()
        follows.attach(social: social, currentUserId: me)
        let posts = [post("p1", by: them, follows: true), post("p2", by: "someone", follows: nil), post("p3", by: me, follows: false)]
            .compactMap { MediaPost(post: $0, currentUserId: me) }
        XCTAssertEqual(posts.count, 3)
        XCTAssertEqual(posts[0].authorFollowed, true)
        follows.note(posts: posts)
        XCTAssertEqual(follows.isFollowing(them), true)
        XCTAssertNil(follows.isFollowing("someone"), "an older server said nothing")
        XCTAssertNil(follows.isFollowing(me))
        follows.attach(social: social, currentUserId: "another-person")
        XCTAssertNil(follows.isFollowing(them))
    }

    func testAPostKeepsItsCommentCountAndFollowFlagWhenSaved() throws {
        let original = try XCTUnwrap(MediaPost(post: post("p1", by: them, follows: true, comments: 4), currentUserId: me))
        let copy = try JSONDecoder().decode(MediaPost.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(copy.comments, 4)
        XCTAssertEqual(copy.authorFollowed, true)
        let older = try JSONDecoder().decode(MediaPost.self, from: Data("""
        {"id": "p", "mediaId": "m", "authorId": "a", "authorName": "A", "likes": 1, "likedByMe": false, "isMine": false}
        """.utf8))
        XCTAssertEqual(older.comments, 0, "a copy saved by an older app version still reads")
        XCTAssertNil(older.authorFollowed)
    }

    // MARK: Comments

    func testCommentsLoadSendAndDelete() async {
        let (social, profiles) = services()
        let model = CommentsModel(postId: postId, postAuthorId: me, social: social, profiles: profiles, currentUserId: me, pageSize: 2)
        var deltas: [Int] = []
        model.onCountChange = { deltas.append($0) }
        MockURLProtocol.requestHandler = { request in
            let path = request.url!.path
            if path.hasPrefix("/v1/auth/users/") {
                return TestFixtures.envelopedResponse(json: "{\"id\": \"\(self.them)\", \"full_name\": \"Dana O&#x27;Neil\", \"username\": \"dana\"}")
            }
            switch request.httpMethod {
            case "GET":
                return TestFixtures.envelopedResponse(json: "{\"comments\": [\(self.comment("c1", by: self.them)), \(self.comment("c2", by: self.them, parent: "c1"))]}")
            case "POST":
                return TestFixtures.envelopedResponse(json: self.comment("c3", by: self.me, text: "mine"))
            default:
                XCTAssertEqual(path, "/v1/social/posts/\(self.postId)/comments/c1")
                return TestFixtures.envelopedResponse(json: "null")
            }
        }
        await model.load()
        XCTAssertEqual(model.comments.map(\.id), ["c1", "c2"])
        XCTAssertTrue(model.hasMore, "a full page: there may be more")
        XCTAssertTrue(model.hasLoaded)

        let empty = await model.send("   ")
        XCTAssertFalse(empty, "nothing to send")
        let sent = await model.send("  mine ")
        XCTAssertTrue(sent)
        XCTAssertEqual(model.comments.first?.id, "c3", "the new comment is on top")
        XCTAssertTrue(model.isMine(model.comments[0]))

        // The post is mine: I may delete anyone's comment, and its replies go with it.
        XCTAssertTrue(model.canDelete(model.comments[1]))
        await model.delete(model.comments[1])
        XCTAssertEqual(model.comments.map(\.id), ["c3"])
        XCTAssertEqual(deltas, [1, -2])
    }

    func testADeleteTheServerRefusesPutsTheCommentBack() async {
        let (social, profiles) = services()
        let model = CommentsModel(postId: postId, postAuthorId: them, social: social, profiles: profiles, currentUserId: me)
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "GET" {
                return TestFixtures.envelopedResponse(json: "{\"comments\": [\(self.comment("c1", by: self.me)), \(self.comment("c2", by: self.them))]}")
            }
            return TestFixtures.mockResponse(statusCode: 500, json: "{\"success\": false, \"error\": {\"code\": \"INTERNAL_ERROR\", \"message\": \"no\"}}")
        }
        await model.load()
        XCTAssertFalse(model.hasMore)
        XCTAssertTrue(model.canDelete(model.comments[0]))
        XCTAssertFalse(model.canDelete(model.comments[1]), "someone else's comment on someone else's post")
        await model.delete(model.comments[0])
        XCTAssertEqual(model.comments.map(\.id), ["c1", "c2"])
        XCTAssertNotNil(model.errorMessage)

        model.setBlocked([them])
        XCTAssertEqual(model.comments.map(\.id), ["c1"], "a blocked person's comments are not shown")
    }

    // MARK: Inbox

    func testInboxCountsUnreadAndOpeningItReadsEverything() async {
        let (social, profiles) = services()
        let inbox = ActivityInboxModel()
        inbox.attach(social: social, profiles: profiles)
        var marked = 0
        MockURLProtocol.requestHandler = { request in
            let path = request.url!.path
            if path.hasPrefix("/v1/auth/users/") { return TestFixtures.envelopedResponse(json: "{\"id\": \"\(self.them)\", \"full_name\": \"Dana\"}") }
            if path.hasSuffix("/unread-count") { return TestFixtures.envelopedResponse(json: "{\"unread\": 5}") }
            if path.hasSuffix("/read-all") { marked += 1; return TestFixtures.envelopedResponse(json: "null") }
            return TestFixtures.envelopedResponse(json: """
            {"activities": [
              {"id": "a1", "activity_type": "follow", "actor_user_id": "\(self.them)", "is_read": false, "created_at": "2026-11-24T10:00:00Z"},
              {"id": "a2", "activity_type": "like", "actor_user_id": "blocked", "target_type": "post", "target_id": "\(self.postId)", "is_read": false, "created_at": "2026-11-24T09:00:00Z"},
              {"id": "a3", "activity_type": "comment", "actor_user_id": "\(self.them)", "target_type": "post", "target_id": "\(self.postId)", "is_read": true, "created_at": "2026-11-24T08:00:00Z"}
            ]}
            """)
        }
        await inbox.refreshUnread()
        XCTAssertEqual(inbox.unread, 5)
        inbox.setBlocked(["blocked"])
        await inbox.load()
        XCTAssertEqual(inbox.items.map(\.id), ["a1", "a3"], "what a blocked person did is not shown")
        XCTAssertEqual(inbox.unread, 1)
        await inbox.markAllRead()
        XCTAssertEqual(inbox.unread, 0)
        XCTAssertTrue(inbox.items.allSatisfy(\.isRead))
        XCTAssertEqual(marked, 1)
        await inbox.markAllRead()
        XCTAssertEqual(marked, 1, "nothing unread: nothing to tell the server")
    }

    // MARK: A person's page

    func testAPersonsPageLoadsCountsAndFollowingMovesTheCount() async {
        let (social, profiles) = services()
        let follows = FollowStore()
        follows.attach(social: social, currentUserId: me)
        let page = PersonProfileModel(userId: them, social: social, profiles: profiles, follows: follows, currentUserId: me, pageSize: 2)
        MockURLProtocol.requestHandler = { request in
            let path = request.url!.path
            if path.hasPrefix("/v1/auth/users/") { return TestFixtures.envelopedResponse(json: "{\"id\": \"\(self.them)\", \"full_name\": \"Dana\", \"username\": \"dana\"}") }
            if path.hasSuffix("/follow-status") {
                return TestFixtures.envelopedResponse(json: "{\"is_following\": false, \"is_followed_by\": true, \"followers_count\": 10, \"following_count\": 2}")
            }
            if path.hasSuffix("/follow") { return TestFixtures.envelopedResponse(json: "null") }
            return TestFixtures.envelopedResponse(json: """
            {"posts": [{"id": "p1", "user_id": "\(self.them)", "content": "x", "media_ids": ["m1"], "visibility": "public",
                        "likes_count": 0, "comments_count": 0, "shares_count": 0, "created_at": "2026-11-24T10:00:00Z"}]}
            """)
        }
        await page.load()
        XCTAssertFalse(page.isMe)
        XCTAssertEqual(page.followersCount, 10)
        XCTAssertEqual(page.followingCount, 2)
        XCTAssertTrue(page.followsMe)
        XCTAssertEqual(page.isFollowing, false)
        XCTAssertEqual(page.posts.map(\.id), ["p1"])
        XCTAssertFalse(page.hasMore, "a short page is the last one")

        let error = await page.toggleFollow()
        XCTAssertNil(error)
        XCTAssertEqual(page.isFollowing, true)
        XCTAssertEqual(page.followersCount, 11)
        await page.toggleFollow()
        XCTAssertEqual(page.followersCount, 10)
    }

    func testFollowersListReadsPeople() async {
        let (social, profiles) = services()
        let list = PeopleListModel(userId: them, kind: .followers, social: social, profiles: profiles, pageSize: 2)
        MockURLProtocol.requestHandler = { request in
            let path = request.url!.path
            if path.hasPrefix("/v1/auth/users/") { return TestFixtures.envelopedResponse(json: "{\"id\": \"\(self.me)\", \"full_name\": \"Me\"}") }
            XCTAssertTrue(path.hasSuffix("/followers"))
            return TestFixtures.envelopedResponse(json: "{\"followers\": [{\"user_id\": \"\(self.me)\", \"followed_at\": \"2026-11-24T10:00:00Z\"}]}")
        }
        await list.load()
        XCTAssertEqual(list.entries.map(\.userId), [me])
        XCTAssertFalse(list.hasMore)
        XCTAssertTrue(list.hasLoaded)
    }
}
