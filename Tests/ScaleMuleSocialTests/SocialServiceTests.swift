import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleSocial

final class SocialServiceTests: XCTestCase {
    static let postJSON = """
    {
        "id": "019b0000-0000-7000-8000-000000000001",
        "user_id": "019b0000-0000-7000-8000-0000000000aa",
        "content": "Ocean Beach",
        "media_ids": ["019b0000-0000-7000-8000-0000000000ff"],
        "media_urls": null,
        "visibility": "public",
        "metadata": {"city": "San Francisco", "lat": 37.76, "author_name": "Sam"},
        "likes_count": 2,
        "comments_count": 0,
        "shares_count": 0,
        "created_at": "2026-11-21T18:00:00.123456Z"
    }
    """

    private func signedIn() async -> (ScaleMuleApp, SocialService) {
        let (app, _) = createTestClient()
        let creds = CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600))
        try? await app.sessionManager.setCredentials(creds)
        return (app, SocialService(app: app))
    }

    func testFeedSendsPaginationAndUnwrapsPosts() async {
        let (_, social) = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let url = request.url!
            XCTAssertEqual(url.path, "/v1/social/feed")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
            XCTAssertEqual(items.first { $0.name == "page" }?.value, "2")
            XCTAssertEqual(items.first { $0.name == "per_page" }?.value, "100")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sess_123")
            return TestFixtures.envelopedResponse(json: "{\"posts\": [\(Self.postJSON)]}")
        }

        let posts = assertApiSuccess(await social.feed(page: 2, perPage: 500))
        XCTAssertEqual(posts?.count, 1)
        let post = posts?.first
        XCTAssertEqual(post?.mediaIds, ["019b0000-0000-7000-8000-0000000000ff"])
        XCTAssertEqual(post?.visibility, .public)
        XCTAssertEqual(post?.likesCount, 2)
        XCTAssertEqual(post?.metadataString("city"), "San Francisco")
        XCTAssertEqual(post?.metadataDouble("lat"), 37.76)
        XCTAssertNotNil(post?.createdDate)
    }

    func testCreatePostSendsBodyAndIsNotRetried() async {
        let (app, _) = createTestClient()
        try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600)))
        // maxRetries 0 in tests; the request itself must say it is not retryable.
        let social = SocialService(client: app.client)
        var calls = 0
        MockURLProtocol.requestHandler = { request in
            calls += 1
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/social/posts")
            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["content"] as? String, "Ocean Beach")
            XCTAssertEqual(body["visibility"] as? String, "public")
            XCTAssertEqual(body["media_ids"] as? [String], ["p1"])
            XCTAssertEqual((body["metadata"] as? [String: Any])?["city"] as? String, "San Francisco")
            return TestFixtures.envelopedResponse(json: Self.postJSON)
        }

        let post = assertApiSuccess(await social.createPost(
            content: "Ocean Beach",
            mediaIds: ["p1"],
            metadata: ["city": "San Francisco"]
        ))
        XCTAssertEqual(post?.content, "Ocean Beach")
        XCTAssertEqual(calls, 1)
    }

    func testCreatePostSendsTheChosenLocation() async {
        let (_, social) = await signedIn()
        MockURLProtocol.requestHandler = { request in
            let body = self.bodyJSON(request)!
            let location = body["location"] as? [String: Any]
            XCTAssertEqual(location?["precision"] as? String, "place")
            XCTAssertEqual(location?["place_id"] as? String, "I63802885C8189B2B")
            XCTAssertEqual(location?["name"] as? String, "SFMOMA")
            XCTAssertEqual(location?["country_code"] as? String, "US")
            XCTAssertNil((body["metadata"] as? [String: Any])?["lat"])
            return TestFixtures.envelopedResponse(json: Self.postJSON)
        }
        let museum = SharedLocation(precision: .place, latitude: 37.7857, longitude: -122.4011,
                                    name: "SFMOMA", locality: "San Francisco", countryCode: "US",
                                    placeId: "I63802885C8189B2B")
        _ = assertApiSuccess(await social.createPost(content: "Rothko", metadata: ["kind": "photo"], location: museum))
    }

    func testAPostForAPetSendsThePetAndReadsThePetAsItsAuthor() async {
        let (_, social) = await signedIn()
        let pet = "019c0000-0000-7000-8000-0000000000e1"
        // What Social answers for an entity's post: the entity everywhere a
        // person would be, and whether the signed-in person made it.
        let answer = Self.postJSON
            .replacingOccurrences(of: "019b0000-0000-7000-8000-0000000000aa", with: pet)
            .replacingOccurrences(of: "\"likes_count\": 2,", with: """
            "likes_count": 2, "entity_id": "\(pet)", "posted_by_viewer": true,
            "author": {"id": "\(pet)", "name": "Mochi", "kind": "pet", "avatar_url": "https://cdn-public.scalemule.com/a/anonymous/mochi.jpg"},
            """)
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/social/posts")
            XCTAssertEqual(self.bodyJSON(request)?["entity_id"] as? String, pet)
            return TestFixtures.envelopedResponse(json: answer)
        }
        let post = assertApiSuccess(await social.createPost(content: "Nap", mediaIds: ["p1"], entityId: pet))
        XCTAssertEqual(post?.userId, pet)
        XCTAssertEqual(post?.entityId, pet)
        XCTAssertEqual(post?.postedByViewer, true)
        XCTAssertEqual(post?.author?.name, "Mochi")
        XCTAssertEqual(post?.author?.kind, "pet")

        // A person's own post sends no entity and reads none.
        MockURLProtocol.requestHandler = { request in
            XCTAssertNil(self.bodyJSON(request)?["entity_id"])
            return TestFixtures.envelopedResponse(json: Self.postJSON)
        }
        let own = assertApiSuccess(await social.createPost(content: "Mine"))
        XCTAssertNil(own?.entityId)
        XCTAssertNil(own?.postedByViewer)
        XCTAssertNil(own?.author?.kind)
    }

    func testAPetsPostsAreReadFromThePetsOwnList() async {
        let (_, social) = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/social/entities/019c0000-0000-7000-8000-0000000000e1/posts")
            return TestFixtures.envelopedResponse(json: "{\"posts\": [\(Self.postJSON)]}")
        }
        let posts = assertApiSuccess(await social.entityPosts(entityId: "019c0000-0000-7000-8000-0000000000e1"))
        XCTAssertEqual(posts?.count, 1)
    }

    func testAPostsPlaceIsChangedOrTakenOff() async {
        let (_, social) = await signedIn()
        let id = "019b0000-0000-7000-8000-000000000001"
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/v1/social/posts/\(id)/location")
            let body = self.bodyJSON(request)!
            XCTAssertTrue(body["location"] is NSNull, "taking the place off sends null")
            return TestFixtures.envelopedResponse(json: Self.postJSON)
        }
        _ = assertApiSuccess(await social.setPostLocation(id: id, location: nil))

        MockURLProtocol.requestHandler = { request in
            let location = self.bodyJSON(request)?["location"] as? [String: Any]
            XCTAssertEqual(location?["precision"] as? String, "city")
            XCTAssertEqual(location?["name"] as? String, "Walnut Creek")
            return TestFixtures.envelopedResponse(json: Self.postJSON)
        }
        let town = SharedLocation(precision: .city, latitude: 37.9101, longitude: -122.0652,
                                  name: "Walnut Creek", locality: "Walnut Creek", countryCode: "US")
        _ = assertApiSuccess(await social.setPostLocation(id: id, location: town))
    }

    func testPostsNearPostsTheSpotInTheBodyAndDecodesThePage() async {
        let (_, social) = await signedIn()
        let located = Self.postJSON.replacingOccurrences(
            of: "\"likes_count\": 2,",
            with: "\"likes_count\": 2, \"distance_km\": 1.4, \"location\": {\"precision\": \"city\", \"latitude\": 37.78, \"longitude\": -122.42, \"name\": \"Сан-Франциско 旧金山 🌉\"},"
        )
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/social/posts/near")
            XCTAssertNil(request.url?.query, "no position in the URL")
            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["latitude"] as? Double, 37.8044)
            XCTAssertEqual(body["radius_km"] as? Double, 25)
            XCTAssertEqual(body["cursor"] as? String, "c1")
            return TestFixtures.envelopedResponse(json: "{\"posts\": [\(located)], \"radius_km\": 25, \"next_cursor\": \"c2\"}")
        }
        let page = assertApiSuccess(await social.postsNear(latitude: 37.8044, longitude: -122.2712, radiusKm: 25, cursor: "c1"))
        XCTAssertEqual(page?.radiusKm, 25)
        XCTAssertEqual(page?.nextCursor, "c2")
        XCTAssertEqual(page?.posts.first?.distanceKm, 1.4)
        XCTAssertEqual(page?.posts.first?.post.location?.label, "Сан-Франциско 旧金山 🌉")
        XCTAssertEqual(page?.posts.first?.post.content, "Ocean Beach")
        XCTAssertNil(page?.posts.first?.post.likedByMe)
    }

    func testNotHereIsRecognised() async {
        let (_, social) = await signedIn()
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 403, json: "{\"success\": false, \"error\": {\"code\": \"LOCATION_NOT_HERE\", \"message\": \"Posts nearby follow where you are.\"}}")
        }
        let error = assertApiFailure(await social.postsAtPlace(placeId: "x", latitude: 51.5, longitude: -0.12))
        XCTAssertEqual(error?.isLocationNotHere, true)
    }

    func testOldPostsWithoutLocationStillDecode() async {
        let (_, social) = await signedIn()
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.envelopedResponse(json: "{\"posts\": [\(Self.postJSON)]}")
        }
        let posts = assertApiSuccess(await social.feed())
        XCTAssertNil(posts?.first?.location)
        let liked = try? JSONDecoder().decode(SocialPost.self, from: Data(Self.postJSON.replacingOccurrences(of: "\"likes_count\": 2,", with: "\"likes_count\": 2, \"liked_by_me\": true,").utf8))
        XCTAssertEqual(liked?.likedByMe, true)
    }

    func testLikeUsesTargetPath() async {
        let (_, social) = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/social/post/abc/like")
            return TestFixtures.mockResponse(statusCode: 200, json: "{\"success\": true, \"data\": null}")
        }
        let liked = await social.like(id: "abc")
        XCTAssertTrue(liked.isSuccess)
    }

    func testUserPostsPath() async {
        let (_, social) = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/social/users/u1/posts")
            return TestFixtures.envelopedResponse(json: "{\"posts\": []}")
        }
        let posts = assertApiSuccess(await social.userPosts(userId: "u1"))
        XCTAssertEqual(posts?.count, 0)
    }
}

extension SocialServiceTests {
    func testCursorFeedPreservesSyncMetadata() async {
        let (app, social) = await signedIn()
        MockURLProtocol.requestHandler = { request in
            let q = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(q, ["after": "newest", "since": "900", "scope": "following", "per_page": "100"])
            return TestFixtures.envelopedResponse(json: #"{"posts":[\#(Self.postJSON)],"as_of":950,"removed":["deleted"],"gap":true}"#)
        }
        let page = assertApiSuccess(await social.feedPage(scope: .following, after: "newest", since: 900, perPage: 500))
        XCTAssertEqual(page?.asOf, 950)
        XCTAssertEqual(page?.removed, ["deleted"])
        XCTAssertEqual(page?.gap, true)
        XCTAssertNil(page?.nextCursor)
        withExtendedLifetime(app) {}
    }

    func testOlderCursorAndUnavailableRemovalsDecode() async {
        let (_, social) = await signedIn()
        MockURLProtocol.requestHandler = { request in
            let q = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(q, ["before": "oldest", "per_page": "20"])
            return TestFixtures.envelopedResponse(json: #"{"posts":[\#(Self.postJSON)],"next_cursor":"older","as_of":950}"#)
        }
        let page = assertApiSuccess(await social.feedPage(before: "oldest"))
        XCTAssertEqual(page?.nextCursor, "older")
        XCTAssertNil(page?.removed, "absent removal history must not be interpreted as authoritative")
        XCTAssertEqual(page?.gap, false)
    }
}
