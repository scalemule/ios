import CoreLocation
import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleSocial
@testable import ScaleMulePhotos
@testable import ScaleMuleMediaPosts
#if canImport(UIKit)
@testable import ScaleMuleMediaQueue
#endif

private func socialPost(_ json: String) throws -> SocialPost {
    try JSONDecoder().decode(SocialPost.self, from: Data(json.utf8))
}

/// A Social post as the feed sends it.
private func postJSON(
    id: String,
    user: String = "u2",
    media: String? = nil,
    likes: Int = 0,
    likedByMe: Bool? = nil,
    metadata: String = #"{"kind":"photo","author_name":"Maya","width":1080,"height":1920}"#,
    location: String? = nil
) -> String {
    var fields = [
        #""id":"\#(id)""#, #""user_id":"\#(user)""#, #""content":"x""#,
        #""media_ids":["\#(media ?? "m-\(id)")"]"#, #""visibility":"public""#,
        #""likes_count":\#(likes)"#, #""comments_count":0"#, #""shares_count":0"#,
        #""metadata":\#(metadata)"#, #""created_at":"2026-11-22T10:00:00Z""#,
    ]
    if let likedByMe { fields.append(#""liked_by_me":\#(likedByMe)"#) }
    if let location { fields.append(#""location":\#(location)"#) }
    return "{" + fields.joined(separator: ",") + "}"
}

private func page(_ ids: [String], user: String = "u2") -> String {
    #"{"posts":[\#(ids.map { postJSON(id: $0, user: user) }.joined(separator: ","))]}"#
}

// MARK: - MediaPost

final class MediaPostTests: XCTestCase {
    func testReadsAnOldPostWithOnlyAPlaceName() throws {
        // Before post locations: the place name in metadata, coordinates
        // (which Social now strips) never used.
        let post = try socialPost(#"""
        {"id":"p1","user_id":"u1","content":"x","media_ids":["photo1"],"visibility":"public",
         "likes_count":3,"comments_count":0,"shares_count":0,
         "metadata":{"place":"San Francisco, CA","lat":37.76,"lon":-122.51,"author_name":"Sam"},
         "created_at":"2026-11-21T18:00:00.5Z"}
        """#)
        let item = try XCTUnwrap(MediaPost(post: post, currentUserId: "someone-else"))
        XCTAssertEqual(item.mediaId, "photo1")
        XCTAssertEqual(item.kind, .photo, "no kind means photo")
        XCTAssertEqual(item.place, "San Francisco, CA")
        XCTAssertNil(item.location)
        XCTAssertNil(item.coordinate)
        XCTAssertNil(item.placeId)
        XCTAssertEqual(item.likes, 3)
        XCTAssertFalse(item.likedByMe)
        XCTAssertFalse(item.isMine)
        XCTAssertNotNil(item.createdAt)
        XCTAssertNil(item.distanceString(from: CLLocation(latitude: 37.77, longitude: -122.42)))
    }

    func testReadsANewPostAtAVenueThatIAlreadyLiked() throws {
        let post = try socialPost(postJSON(
            id: "p2", user: "u1", likes: 1, likedByMe: true,
            metadata: #"{"kind":"photo","author_name":"Sam","place":"SFMOMA","width":1600,"height":1200,"caption":"Rothko"}"#,
            location: #"{"precision":"place","latitude":37.7857,"longitude":-122.4011,"name":"SFMOMA","place_id":"I6380"}"#
        ))
        let item = try XCTUnwrap(MediaPost(post: post, currentUserId: "u1"))
        XCTAssertTrue(item.isMine)
        XCTAssertEqual(item.place, "SFMOMA")
        XCTAssertEqual(item.placeId, "I6380")
        XCTAssertEqual(item.precision, .place)
        XCTAssertEqual(item.caption, "Rothko")
        XCTAssertTrue(item.isLandscape)
        XCTAssertTrue(item.likedByMe)
        XCTAssertEqual(item.likeCount(liked: true), 1, "a like already counted is not counted again")
        XCTAssertEqual(item.likeCount(liked: false), 0)
        XCTAssertNotNil(item.distanceString(from: CLLocation(latitude: 37.77, longitude: -122.42)))
        let saved = try JSONDecoder().decode(MediaPost.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(saved.location, item.location)
        XCTAssertEqual(saved.placeId, "I6380")
        XCTAssertTrue(saved.likedByMe)
    }

    func testCityAndAreaPostsShowNoDistanceOrVenue() throws {
        let city = try XCTUnwrap(MediaPost(post: socialPost(postJSON(
            id: "p3", location: #"{"precision":"city","latitude":37.8,"longitude":-122.28,"name":"Oakland","place_id":"ignored"}"#
        )), currentUserId: nil))
        XCTAssertEqual(city.place, "Oakland")
        XCTAssertNil(city.placeId)
        XCTAssertNil(city.distanceString(from: CLLocation(latitude: 37.77, longitude: -122.42)))
        let area = try XCTUnwrap(MediaPost(post: socialPost(postJSON(
            id: "p4", location: #"{"precision":"area","latitude":37.8,"longitude":-122.28,"locality":"Oakland"}"#
        )), currentUserId: nil))
        XCTAssertEqual(area.place, "near Oakland")
    }

    func testUnicodeTextSurvivesReadingAndSaving() throws {
        let post = try socialPost(postJSON(
            id: "p5",
            metadata: #"{"author_name":"Мария","caption":"東京の夜 🌉👩‍👩‍👧 Привет","place":"Сан-Франциско"}"#,
            location: #"{"precision":"exact","latitude":37.78,"longitude":-122.42,"name":"旧金山 🌁"}"#
        ))
        let item = try XCTUnwrap(MediaPost(post: post, currentUserId: nil))
        XCTAssertEqual(item.authorName, "Мария")
        XCTAssertEqual(item.caption, "東京の夜 🌉👩‍👩‍👧 Привет")
        XCTAssertEqual(item.place, "旧金山 🌁")
        let saved = try JSONDecoder().decode(MediaPost.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(saved.caption, item.caption)
        XCTAssertEqual(saved.place, item.place)
        XCTAssertEqual(saved.authorName, "Мария")
    }

    func testVideoPostsAndFallbackNames() throws {
        let video = try XCTUnwrap(MediaPost(post: socialPost(postJSON(
            id: "p6", media: "vid-1", metadata: #"{"kind":"video","author_name":"","width":1080,"height":1920,"duration":12.4}"#
        )), currentUserId: "u2"))
        XCTAssertTrue(video.isVideo)
        XCTAssertEqual(video.mediaId, "vid-1")
        XCTAssertEqual(video.duration, 12.4)
        XCTAssertFalse(video.isLandscape)
        XCTAssertEqual(video.authorName, "You", "your own post without a name")
        let other = try XCTUnwrap(MediaPost(post: socialPost(postJSON(id: "p7", metadata: "{}")), currentUserId: "u1"))
        XCTAssertEqual(other.authorName, "Someone")
        XCTAssertNil(MediaPost(post: try socialPost(#"""
        {"id":"t","user_id":"u1","content":"text only","visibility":"public",
         "likes_count":0,"comments_count":0,"shares_count":0,"created_at":"2026-11-21T18:00:00Z"}
        """#), currentUserId: nil), "posts without media are skipped")
    }

    func testReadsCopiesSavedByEarlierFirehosyVersions() throws {
        let old = #"""
        [{"id":"p8","photoId":"photo8","authorId":"u3","authorName":"Diego","place":"SFMOMA",
          "latitude":37.7857,"longitude":-122.4011,"precision":"place","placeId":"I6380",
          "width":1080,"height":1440,"createdAt":785000000,"isMine":false,"likesCount":4,
          "likedAtLoad":true,"kind":"video","duration":7.5}]
        """#
        let item = try XCTUnwrap(JSONDecoder().decode([MediaPost].self, from: Data(old.utf8)).first)
        XCTAssertEqual(item.mediaId, "photo8")
        XCTAssertEqual(item.likes, 4)
        XCTAssertTrue(item.likedByMe)
        XCTAssertEqual(item.placeId, "I6380")
        XCTAssertEqual(item.place, "SFMOMA")
        XCTAssertTrue(item.isVideo)
        XCTAssertEqual(item.duration, 7.5)
    }

    func testTimeAgo() throws {
        let item = try XCTUnwrap(MediaPost(post: socialPost(postJSON(id: "p9")), currentUserId: nil))
        let created = try XCTUnwrap(item.createdAt)
        XCTAssertEqual(item.timeAgo(now: created.addingTimeInterval(30)), "Just now")
        XCTAssertEqual(item.timeAgo(now: created.addingTimeInterval(300)), "5m ago")
        XCTAssertEqual(item.timeAgo(now: created.addingTimeInterval(3 * 3600)), "3h ago")
        XCTAssertEqual(item.timeAgo(now: created.addingTimeInterval(2 * 86400)), "2d ago")
    }
}

// MARK: - Publisher

final class MediaPostPublisherTests: XCTestCase {
    private func signedIn() async -> ScaleMuleApp {
        let (app, _) = createTestClient()
        try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600)))
        return app
    }

    private static let created = postJSON(
        id: "new-1", user: "u1", media: "photo-9",
        metadata: #"{"kind":"photo","author_name":"Sam","width":1080,"height":1440,"place":"SFMOMA","caption":"Fog 霧 🌫"}"#,
        location: #"{"precision":"place","latitude":37.7857,"longitude":-122.4011,"name":"SFMOMA","place_id":"I6380"}"#
    )

    func testSendsTheLocationAndNeverCoordinatesInMetadata() async throws {
        let app = await signedIn()
        let publisher = MediaPostPublisher(social: SocialService(app: app), tags: ["firehosy-world"])
        var body: [String: Any]?
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/social/posts")
            body = self.bodyJSON(request)
            return TestFixtures.envelopedResponse(json: Self.created)
        }
        let venue = SharedLocation(precision: .place, latitude: 37.7857, longitude: -122.4011, name: "SFMOMA", placeId: "I6380")
        let result = await publisher.publish(
            mediaId: "photo-9", kind: .photo, width: 1080, height: 1440,
            caption: "Fog 霧 🌫", location: venue, authorName: "Sam"
        )
        let post = try XCTUnwrap(assertApiSuccess(result))
        XCTAssertEqual(post.id, "new-1")
        XCTAssertTrue(post.isMine)
        XCTAssertEqual(post.placeId, "I6380")

        let sent = try XCTUnwrap(body)
        XCTAssertEqual(sent["content"] as? String, "Fog 霧 🌫")
        XCTAssertEqual(sent["media_ids"] as? [String], ["photo-9"])
        XCTAssertEqual(sent["tags"] as? [String], ["firehosy-world"])
        XCTAssertEqual(sent["visibility"] as? String, "public")
        let metadata = try XCTUnwrap(sent["metadata"] as? [String: Any])
        XCTAssertEqual(Set(metadata.keys), ["kind", "author_name", "width", "height", "place", "caption"])
        XCTAssertEqual(metadata["kind"] as? String, "photo")
        XCTAssertEqual(metadata["author_name"] as? String, "Sam")
        XCTAssertEqual(metadata["place"] as? String, "SFMOMA")
        XCTAssertEqual(metadata["width"] as? Int, 1080)
        for key in ["lat", "lon", "latitude", "longitude", "lng"] {
            XCTAssertNil(metadata[key], "no coordinates in metadata (\(key))")
        }
        let location = try XCTUnwrap(sent["location"] as? [String: Any])
        XCTAssertEqual(location["precision"] as? String, "place")
        XCTAssertEqual(location["place_id"] as? String, "I6380")
        XCTAssertEqual(location["latitude"] as? Double, 37.7857)
    }

    func testVideoWithoutCaptionOrLocation() async throws {
        let app = await signedIn()
        let publisher = MediaPostPublisher(social: SocialService(app: app))
        var body: [String: Any]?
        MockURLProtocol.requestHandler = { request in
            body = self.bodyJSON(request)
            return TestFixtures.envelopedResponse(json: postJSON(id: "v", user: "u1", media: "vid-2", metadata: #"{"kind":"video"}"#))
        }
        let result = await publisher.publish(
            mediaId: "vid-2", kind: .video, width: 1080, height: 1920, duration: 12.44,
            caption: "", location: nil, authorName: ""
        )
        XCTAssertEqual(assertApiSuccess(result)?.kind, .video)
        let sent = try XCTUnwrap(body)
        XCTAssertEqual(sent["content"] as? String, "Right now")
        XCTAssertNil(sent["location"])
        XCTAssertNil(sent["tags"])
        let metadata = try XCTUnwrap(sent["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["duration"] as? Double, 12.4)
        XCTAssertNil(metadata["place"])
        XCTAssertNil(metadata["caption"])
    }

    func testContentIsThePlaceWhenThereIsNoCaption() async throws {
        let app = await signedIn()
        var body: [String: Any]?
        MockURLProtocol.requestHandler = { request in
            body = self.bodyJSON(request)
            return TestFixtures.envelopedResponse(json: Self.created)
        }
        let city = SharedLocation(precision: .city, latitude: 37.8, longitude: -122.27, name: "Oakland")
        _ = await MediaPostPublisher(social: SocialService(app: app)).publish(
            mediaId: "photo-9", kind: .photo, width: 1, height: 1, caption: "", location: city, authorName: "Sam"
        )
        XCTAssertEqual(body?["content"] as? String, "Oakland")
    }

    func testAttributesKeepTheChosenLocationOnly() {
        let oakland = SharedLocation(precision: .city, latitude: 37.80, longitude: -122.28, name: "Oakland 東京 🌉")
        let attributes = MediaPostAttributes.make(caption: "hi", location: oakland)
        XCTAssertEqual(MediaPostAttributes.location(attributes), oakland)
        XCTAssertEqual(MediaPostAttributes.caption(attributes), "hi")
        XCTAssertNil(attributes["lat"])
        XCTAssertNil(MediaPostAttributes.location(MediaPostAttributes.make(caption: "", location: nil)))
        // Queued with loose coordinates: posted without a location.
        XCTAssertNil(MediaPostAttributes.location(["lat": "37.77", "lon": "-122.42", "place": "SF"]))
    }

    func testAuthorNameIsTheFirstName() {
        XCTAssertEqual(MediaPostPublisher.authorName(for: AuthUser(id: "u1", username: "sammy", fullName: "Sam Rivera")), "Sam")
        XCTAssertEqual(MediaPostPublisher.authorName(for: AuthUser(id: "u1", username: "sammy")), "sammy")
        XCTAssertEqual(MediaPostPublisher.authorName(for: AuthUser(id: "u1", fullName: "Мария Иванова")), "Мария")
        XCTAssertEqual(MediaPostPublisher.authorName(for: AuthUser(id: "u1")), "")
    }

    #if canImport(UIKit)
    func testPublishesAQueuedUpload() async throws {
        let app = await signedIn()
        var body: [String: Any]?
        MockURLProtocol.requestHandler = { request in
            body = self.bodyJSON(request)
            return TestFixtures.envelopedResponse(json: Self.created)
        }
        let venue = SharedLocation(precision: .place, latitude: 37.7857, longitude: -122.4011, name: "SFMOMA", placeId: "I6380")
        let upload = MediaUpload(
            id: UUID(), kind: .photo, mediaId: "photo-9", width: 1080, height: 1440, duration: nil,
            attributes: MediaPostAttributes.make(caption: "Fog", location: venue)
        )
        let result = await MediaPostPublisher(social: SocialService(app: app)).publish(upload, authorName: "Sam")
        XCTAssertNotNil(assertApiSuccess(result))
        XCTAssertEqual(body?["content"] as? String, "Fog")
        XCTAssertEqual((body?["location"] as? [String: Any])?["place_id"] as? String, "I6380")
        XCTAssertEqual((body?["metadata"] as? [String: Any])?["place"] as? String, "SFMOMA")
    }
    #endif
}

// MARK: - SocialFeedModel

/// Answers requests by path; records what was asked.
private final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [String] = []
    var requests: [String] { lock.withLock { _requests } }

    func start(_ answer: @escaping (URLRequest) -> (HTTPURLResponse, Data)) {
        MockURLProtocol.requestHandler = { [self] request in
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "page" }?.value
            lock.withLock { _requests.append("\(request.httpMethod ?? "") \(request.url!.path)\(page.map { "?page=\($0)" } ?? "")") }
            return answer(request)
        }
    }
}

private func ok(_ json: String) -> (HTTPURLResponse, Data) { TestFixtures.envelopedResponse(json: json) }
private let emptyOK = TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":null}"#)

@MainActor
final class SocialFeedModelTests: XCTestCase {
    private var folder: URL!
    private let server = FakeServer()

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("feedkit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func model(user: String? = "u1") async -> SocialFeedModel {
        let (app, _) = createTestClient()
        try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600)))
        let model = SocialFeedModel(pageSize: 3, cacheDirectory: folder)
        model.attach(social: SocialService(app: app), photos: PhotosService(app: app), currentUserId: user)
        return model
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 3) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testPagesAndStopsAtAShortPage() async {
        server.start { request in
            request.url!.query!.contains("page=1") ? ok(page(["a", "b", "c"])) : ok(page(["c", "d"]))
        }
        let model = await model()
        await model.loadFeed()
        XCTAssertEqual(model.items.map(\.id), ["a", "b", "c"])
        XCTAssertTrue(model.hasMore)
        XCTAssertTrue(model.hasLoaded)
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.id), ["a", "b", "c", "d"], "posts already shown are skipped")
        XCTAssertFalse(model.hasMore, "a short page is the last")
        await model.loadMore()
        XCTAssertEqual(server.requests, ["GET /v1/social/feed?page=1", "GET /v1/social/feed?page=2"])
    }

    func testMineListsYourOwnPosts() async {
        server.start { _ in ok(page(["m1"], user: "u1")) }
        let model = await model()
        model.filter = .mine
        await waitUntil { model.hasLoaded }
        XCTAssertEqual(model.items.map(\.id), ["m1"])
        XCTAssertTrue(model.items[0].isMine)
        XCTAssertEqual(server.requests, ["GET /v1/social/users/u1/posts?page=1"])
    }

    func testAStaleLoadNeverOverwritesANewerFilter() async {
        server.start { request in
            if request.url!.path == "/v1/social/feed" {
                Thread.sleep(forTimeInterval: 0.4)
                return ok(page(["everyone-1"]))
            }
            return ok(page(["mine-1"], user: "u1"))
        }
        let model = await model()
        let slow = Task { await model.loadFeed() }
        await waitUntil { !self.server.requests.isEmpty }
        model.filter = .mine
        await slow.value
        await waitUntil { model.items.first?.id == "mine-1" }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.items.map(\.id), ["mine-1"])
        XCTAssertNil(model.error)
        XCTAssertTrue(model.savedPage().isEmpty, "the stale page was not saved either")
    }

    func testLikesFromTheServerAndOptimisticToggle() async {
        server.start { request in
            switch (request.httpMethod, request.url!.path) {
            case ("GET", _):
                return ok(#"{"posts":[\#(postJSON(id: "a", likes: 2, likedByMe: true)),\#(postJSON(id: "b")),\#(postJSON(id: "c"))]}"#)
            case ("DELETE", "/v1/social/post/a/like"):
                return TestFixtures.mockResponse(statusCode: 500, json: #"{"success":false,"error":{"code":"INTERNAL_ERROR","message":"boom"}}"#)
            case ("POST", "/v1/social/post/b/like"):
                return TestFixtures.mockResponse(statusCode: 409, json: #"{"success":false,"error":{"code":"CONFLICT","message":"Already liked"}}"#)
            default:
                return emptyOK
            }
        }
        let model = await model()
        await model.loadFeed()
        let (a, b, c) = (model.items[0], model.items[1], model.items[2])
        XCTAssertEqual(model.likedIds, ["a"])
        XCTAssertEqual(model.likeCount(a), 2)

        await model.toggleLike(a)
        XCTAssertTrue(model.isLiked(a), "the server refused the unlike: put back")
        await model.toggleLike(b)
        XCTAssertTrue(model.isLiked(b), "409: it was already liked")
        XCTAssertEqual(model.likeCount(b), 1)
        await model.toggleLike(c)
        XCTAssertTrue(model.isLiked(c))
        XCTAssertTrue(server.requests.contains("POST /v1/social/post/c/like"))
    }

    func testReportedPostsAndBlockedPeopleDisappear() async {
        server.start { _ in
            ok(#"{"posts":[\#(postJSON(id: "a", user: "bad")),\#(postJSON(id: "b", user: "u2")),\#(postJSON(id: "c", user: "u3"))]}"#)
        }
        let model = await model()
        await model.loadFeed()
        model.hideReported(model.items[1])
        XCTAssertEqual(model.items.map(\.id), ["a", "c"])

        let bad = model.items[0]
        await model.block(bad) {
            .failure(ApiError(code: .forbidden, message: "Not allowed", statusCode: 403))
        }
        XCTAssertEqual(model.error?.localizedDescription, "Not allowed")
        await model.loadFeed()
        XCTAssertEqual(model.items.map(\.id), ["a", "c"], "a failed block is undone: the next load shows them")

        await model.block(bad) { .success(EmptyResponse()) }
        XCTAssertEqual(model.items.map(\.id), ["c"])

        // Reloading keeps them hidden, and the reported post too.
        await model.loadFeed()
        XCTAssertEqual(model.items.map(\.id), ["c"])
        model.setBlockedAuthors([])
        await model.loadFeed()
        XCTAssertEqual(model.items.map(\.id), ["a", "c"])
    }

    func testNewPostsWaitUntilShown() async {
        var top = ["b", "c"]
        let lock = NSLock()
        server.start { _ in ok(page(lock.withLock { top })) }
        let model = await model()
        await model.loadFeed()
        lock.withLock { top = ["x", "y", "b"] }

        model.pollInterval = 0.05
        model.startPolling()
        await waitUntil { !model.newItems.isEmpty }
        model.stopPolling()
        XCTAssertEqual(model.newItems.map(\.id), ["x", "y"])
        XCTAssertEqual(model.items.map(\.id), ["b", "c"], "the page under the thumb does not jump")

        model.showNewItems()
        XCTAssertEqual(model.items.map(\.id), ["x", "y", "b", "c"])
        XCTAssertTrue(model.newItems.isEmpty)
    }

    func testOpensOnTheSavedFirstPage() async {
        server.start { _ in ok(page(["a", "b", "c", "d"])) }
        let first = await model()
        await first.loadFeed()
        XCTAssertEqual(first.items.count, 4)

        let reopened = await model()
        XCTAssertEqual(reopened.items.map(\.id), ["a", "b", "c"], "the first page, before any network")
        let someoneElse = await model(user: "u9")
        XCTAssertTrue(someoneElse.items.isEmpty, "saved per person")
    }

    func testOpensOnAPageSavedByEarlierFirehosyVersions() async throws {
        let old = #"[{"id":"p8","photoId":"photo8","authorId":"u3","authorName":"Diego","isMine":false,"likesCount":4,"likedAtLoad":true}]"#
        try Data(old.utf8).write(to: folder.appendingPathComponent("feed-u1.json"))
        let model = await model()
        XCTAssertEqual(model.items.map(\.mediaId), ["photo8"])
        XCTAssertEqual(model.likedIds, ["p8"])
    }

    func testDeletesYourOwnPostAndItsPhoto() async {
        server.start { request in
            request.httpMethod == "GET" ? ok(page(["own"], user: "u1")) : emptyOK
        }
        let model = await model()
        await model.loadFeed()
        await model.deleteOwnPost(model.items[0])
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(server.requests.contains("DELETE /v1/social/posts/own"))
        XCTAssertTrue(server.requests.contains("DELETE /v1/photos/m-own"))
    }

    func testInsertsYourNewPostAtTheTop() async throws {
        server.start { _ in ok(page(["a"])) }
        let model = await model()
        await model.loadFeed()
        let mine = try XCTUnwrap(MediaPost(post: socialPost(postJSON(id: "new", user: "u1")), currentUserId: "u1"))
        model.insertOwnPost(mine)
        model.insertOwnPost(mine)
        XCTAssertEqual(model.items.map(\.id), ["new", "a"])
    }

    func testFixedContentLoadsNothing() async throws {
        server.start { _ in ok(page(["a"])) }
        let model = await model()
        let sample = try XCTUnwrap(MediaPost(post: socialPost(postJSON(id: "s")), currentUserId: nil))
        model.showFixed([sample], newItems: [sample])
        await model.loadFeed()
        await model.loadMore()
        await model.checkForNewPosts()
        XCTAssertEqual(model.items.map(\.id), ["s"])
        XCTAssertTrue(model.hasLoaded)
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testNearbyProblemsKeepTheirWords() {
        XCTAssertEqual(SocialFeedModel.defaultNearbyMessage(.locationOff), "Turn on location to see photos near you.")
        XCTAssertEqual(SocialFeedModel.defaultNearbyMessage(.locationUnavailable), "Couldn't find where you are. Try again in a moment.")
        XCTAssertEqual(SocialFeedModel.defaultNearbyMessage(.notHere), "Nearby shows photos around where you are right now.")
        XCTAssertEqual(SocialFeedModel.defaultNearbyMessage(.failed("Offline")), "Offline")
    }
}

#if canImport(UIKit)
import UIKit

@MainActor
final class MediaPostViewsTests: XCTestCase {
    func testPhotosAreFetchedAtTheirFeedSize() {
        XCTAssertEqual(RemotePhotoView.requestWidth(wide: false), 1080)
        XCTAssertEqual(RemotePhotoView.requestWidth(wide: true), 1600)
        let square = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }
        let upright = UIGraphicsImageRenderer(size: CGSize(width: 9, height: 16)).image { _ in }
        XCTAssertTrue(RemotePhotoView.isWide(square), "squares pan too")
        XCTAssertFalse(RemotePhotoView.isWide(upright))
    }

    func testEachProfilePhotoLinkIsCachedOnItsOwn() {
        let link = URL(string: "https://cdn-public.scalemule.com/019b247f-00c7-7443-a366-49435cd11a2b/anonymous/photos/01a2078f-58d2-770c-aa28-1d19d40ec4b1/w256_h256_cover_q85_jpeg.jpeg")!
        let other = URL(string: "https://cdn-public.scalemule.com/019b247f-00c7-7443-a366-49435cd11a2b/anonymous/photos/01a2078f-b686-738a-9998-08ac64e21ac1/w256_h256_cover_q85_jpeg.jpeg")!
        XCTAssertEqual(ProfileAvatarView.cacheKey(for: link), "01a2078f-58d2-770c-aa28-1d19d40ec4b1-w256_h256_cover_q85_jpeg.jpeg")
        XCTAssertNotEqual(ProfileAvatarView.cacheKey(for: link), ProfileAvatarView.cacheKey(for: other))
        XCTAssertEqual(ProfileAvatarView.initial(of: "élodie"), "É")
        XCTAssertEqual(ProfileAvatarView.initial(of: "мария"), "М")
        XCTAssertEqual(ProfileAvatarView.initial(of: "👩‍👩‍👧 family"), "👩‍👩‍👧", "a whole emoji, never half of one")
        XCTAssertEqual(ProfileAvatarView.initial(of: ""), "")
    }
}
#endif
