import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleProfiles

/// A clock the tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
}

/// Counts requests from the URL protocol's thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func hit(_ key: String) { lock.lock(); counts[key, default: 0] += 1; lock.unlock() }
    func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key] ?? 0 }
}

final class PublicProfilesTests: XCTestCase {
    static let avatar = "https://cdn-public.scalemule.com/app/anonymous/photos/01a20787-f585-77fc-9732-476c8f8db99e/w256_h256_cover_q85_jpeg.jpg"

    /// Auth's contact-free view of another person.
    static func contactFree(id: String, name: String? = "Sam O&#x27;Brien", avatar: String? = PublicProfilesTests.avatar) -> String {
        let n = name.map { "\"\($0)\"" } ?? "null"
        let a = avatar.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":"\(id)","sm_application_id":"app","full_name":\(n),"username":"sam","avatar_url":\(a),
         "status":"active","actor_type":"human","created_at":"2026-11-01T00:00:00Z","locale":null,"time_zone":null}
        """
    }

    /// Whether the session could be stored (the iOS simulator's test host has no keychain).
    private var sessionStored = false

    private func makeDirectory(clock: TestClock) async -> PublicProfiles {
        let (app, _) = createTestClient()
        try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600)))
        sessionStored = await app.sessionManager.sessionToken != nil
        return PublicProfiles(client: app.client, ttl: 600, missTTL: 60, now: { clock.now })
    }

    func testFirstNameIsTheFirstWord() {
        func profile(_ name: String?) -> PublicProfile { PublicProfile(id: "u", name: name, username: nil, avatarURL: nil) }
        XCTAssertEqual(profile("Maya Okafor").firstName, "Maya")
        XCTAssertEqual(profile("  Иван  Петров").firstName, "Иван")
        XCTAssertEqual(profile("李 雷").firstName, "李")
        XCTAssertEqual(profile("Zoë").firstName, "Zoë")
        XCTAssertNil(profile(nil).firstName)
        XCTAssertNil(profile("   ").firstName)
    }

    func testLooksUpOnceAndServesFromCacheUntilTTL() async {
        let clock = TestClock()
        let profiles = await makeDirectory(clock: clock)
        let counter = Counter()
        let expectSession = sessionStored
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/auth/users/u1")
            if expectSession { XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sess_123") }
            counter.hit("u1")
            return TestFixtures.envelopedResponse(json: Self.contactFree(id: "u1"))
        }
        let first = await profiles.profile("u1")
        XCTAssertEqual(first, PublicProfile(id: "u1", name: "Sam O'Brien", username: "sam", avatarURL: URL(string: Self.avatar)))
        clock.advance(599)
        _ = await profiles.profile("u1")
        XCTAssertEqual(counter.count("u1"), 1, "fresh for 10 minutes")
        let cached = await profiles.cached("u1")
        XCTAssertEqual(cached?.name, "Sam O'Brien")
        clock.advance(2)
        _ = await profiles.profile("u1")
        XCTAssertEqual(counter.count("u1"), 2, "asked again after the TTL")
    }

    func testConcurrentLookupsShareOneRequest() async {
        let clock = TestClock()
        let profiles = await makeDirectory(clock: clock)
        let counter = Counter()
        MockURLProtocol.requestHandler = { _ in
            counter.hit("u2")
            Thread.sleep(forTimeInterval: 0.2)
            return TestFixtures.envelopedResponse(json: Self.contactFree(id: "u2"))
        }
        let results = await withTaskGroup(of: PublicProfile?.self) { group -> [PublicProfile?] in
            for _ in 0..<10 { group.addTask { await profiles.profile("u2") } }
            var all: [PublicProfile?] = []
            for await result in group { all.append(result) }
            return all
        }
        XCTAssertEqual(results.count, 10)
        XCTAssertTrue(results.allSatisfy { $0?.id == "u2" })
        XCTAssertEqual(counter.count("u2"), 1)
    }

    func testMissesAreRememberedBriefly() async {
        let clock = TestClock()
        let profiles = await makeDirectory(clock: clock)
        let counter = Counter()
        MockURLProtocol.requestHandler = { _ in
            counter.hit("gone")
            return TestFixtures.mockResponse(statusCode: 404, json: #"{"success":false,"error":{"code":"NOT_FOUND","message":"User not found"}}"#)
        }
        let missing = await profiles.profile("gone")
        XCTAssertNil(missing)
        clock.advance(59)
        _ = await profiles.profile("gone")
        XCTAssertEqual(counter.count("gone"), 1)
        clock.advance(2)
        _ = await profiles.profile("gone")
        XCTAssertEqual(counter.count("gone"), 2, "a miss is kept for a minute only")
    }

    func testNoPhotoAndUnsafeLinksBecomeNil() async {
        let clock = TestClock()
        let profiles = await makeDirectory(clock: clock)
        MockURLProtocol.requestHandler = { request in
            switch request.url!.lastPathComponent {
            case "empty": return TestFixtures.envelopedResponse(json: Self.contactFree(id: "empty", name: "  ", avatar: ""))
            case "http": return TestFixtures.envelopedResponse(json: Self.contactFree(id: "http", avatar: "http://example.com/a.jpg"))
            default: return TestFixtures.envelopedResponse(json: Self.contactFree(id: "script", avatar: "javascript:alert(1)"))
            }
        }
        let empty = await profiles.profile("empty")
        XCTAssertNotNil(empty)
        XCTAssertNil(empty?.avatarURL)
        XCTAssertNil(empty?.name)
        let http = await profiles.profile("http")
        XCTAssertNil(http?.avatarURL)
        let script = await profiles.profile("script")
        XCTAssertNil(script?.avatarURL)
    }

    func testRememberForgetAndRemoveAll() async {
        let clock = TestClock()
        let profiles = await makeDirectory(clock: clock)
        let counter = Counter()
        MockURLProtocol.requestHandler = { request in
            counter.hit(request.url!.lastPathComponent)
            return TestFixtures.envelopedResponse(json: Self.contactFree(id: request.url!.lastPathComponent))
        }
        await profiles.remember(PublicProfile(id: "me", name: "Me", username: nil, avatarURL: nil))
        let me = await profiles.profile("me")
        XCTAssertEqual(me?.name, "Me")
        XCTAssertEqual(counter.count("me"), 0)
        await profiles.forget("me")
        _ = await profiles.profile("me")
        XCTAssertEqual(counter.count("me"), 1)
        await profiles.removeAll()
        let afterClear = await profiles.cached("me")
        XCTAssertNil(afterClear)
        let blank = await profiles.profile("  ")
        XCTAssertNil(blank)
    }

    func testCapacityDropsTheOldest() async {
        let clock = TestClock()
        let (app, _) = createTestClient()
        let profiles = PublicProfiles(client: app.client, capacity: 2, now: { clock.now })
        await profiles.remember(PublicProfile(id: "a", name: nil, username: nil, avatarURL: nil))
        clock.advance(1)
        await profiles.remember(PublicProfile(id: "b", name: nil, username: nil, avatarURL: nil))
        clock.advance(1)
        await profiles.remember(PublicProfile(id: "c", name: nil, username: nil, avatarURL: nil))
        let a = await profiles.cached("a")
        let c = await profiles.cached("c")
        XCTAssertNil(a)
        XCTAssertNotNil(c)
    }
}
