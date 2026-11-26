import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMulePush

final class QuietHoursTests: XCTestCase {
    func testOvernightAndTravelUseTheReceivingDevicesClock() {
        let schedule = PushQuietHours.overnight
        let date = ISO8601DateFormatter().date(from: "2026-11-26T00:00:00Z")!
        XCTAssertTrue(schedule.isQuiet(at: date, deviceTimeZone: TimeZone(identifier: "Europe/London")!))
        XCTAssertFalse(schedule.isQuiet(at: date, deviceTimeZone: TimeZone(identifier: "Asia/Tokyo")!))
        var fixed = schedule; fixed.timeZoneIdentifier = "Europe/London"
        XCTAssertTrue(fixed.isQuiet(at: date, deviceTimeZone: TimeZone(identifier: "Asia/Tokyo")!))
        fixed.enabled = false
        XCTAssertFalse(fixed.isQuiet(at: date))
    }
    func testBoundaryAndInvalidSchedules() {
        XCTAssertFalse(PushQuietHours(startMinutes: 480, endMinutes: 480).isValid)
        XCTAssertFalse(PushQuietHours(startMinutes: -1).isValid)
        XCTAssertFalse(PushQuietHours(timeZoneIdentifier: "Mars/Space").isValid)
        let schedule = PushQuietHours.overnight
        XCTAssertTrue(schedule.isQuiet(at: ISO8601DateFormatter().date(from: "2026-11-26T22:00:00Z")!, deviceTimeZone: TimeZone(secondsFromGMT: 0)!))
        XCTAssertFalse(schedule.isQuiet(at: ISO8601DateFormatter().date(from: "2026-11-26T08:00:00Z")!, deviceTimeZone: TimeZone(secondsFromGMT: 0)!))
    }
    func testSpringAndFallClockChanges() {
        let schedule = PushQuietHours(startMinutes: 22 * 60, endMinutes: 90)
        XCTAssertTrue(schedule.isQuiet(at: ISO8601DateFormatter().date(from: "2026-11-01T06:15:00Z")!, deviceTimeZone: TimeZone(identifier: "America/New_York")!))
        XCTAssertFalse(PushQuietHours.overnight.isQuiet(at: ISO8601DateFormatter().date(from: "2026-03-08T12:00:00Z")!, deviceTimeZone: TimeZone(identifier: "America/New_York")!))
    }
}

#if os(macOS)
final class QuietHoursHTTPTests: XCTestCase {
    private let user = "019b0000-0000-7000-8000-000000000002"
    private let preferences = "{\"marketing_enabled\":false,\"transactional_enabled\":true,\"alert_enabled\":true,\"quiet_hours_enabled\":true,\"quiet_hours_start\":\"22:00\",\"quiet_hours_end\":\"08:00\",\"quiet_hours_tz\":null}"
    private func service() async -> PushService {
        let (app, _) = createTestClient()
        try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "current-account", sessionExpiresAt: Date().addingTimeInterval(3600)))
        return PushService(app: app)
    }
    override func tearDown() { MockURLProtocol.requestHandler = nil }
    func testRegistrationRefreshSendsCurrentTimezoneAndDefaultsWithoutChangingOwner() async {
        let service = await service()
        var zones: [String] = []
        MockURLProtocol.requestHandler = { request in
            let body = self.bodyJSON(request)!
            zones.append(body["timezone"] as! String)
            XCTAssertEqual((body["quiet_hours_defaults"] as? [String: String])?["start"], "22:00")
            XCTAssertNil(body["user_id"])
            return TestFixtures.envelopedResponse(json: "{\"id\":\"019b0000-0000-7000-8000-000000000003\",\"user_id\":\"\(self.user)\",\"platform\":\"ios\",\"is_active\":true,\"notifications_enabled\":true}")
        }
        for zone in ["America/Los_Angeles", "Asia/Tokyo"] {
            let result = await service.register(deviceToken: Data([1,2]), userId: user, timeZone: zone, defaultQuietHours: .overnight)
            XCTAssertTrue(result.isSuccess)
        }
        XCTAssertEqual(zones, ["America/Los_Angeles", "Asia/Tokyo"])
    }
    func testSaveFollowsDeviceExplicitlyAndPreservesOtherPreferences() async {
        let service = await service()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer current-account")
            XCTAssertEqual(request.httpMethod, "PUT")
            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["quiet_hours_follow_device"] as? Bool, true)
            XCTAssertNil(body["quiet_hours_tz"])
            XCTAssertNil(body["marketing_enabled"])
            return TestFixtures.envelopedResponse(json: self.preferences)
        }
        let result = await service.setQuietHours(.overnight)
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.data?.quietHours, .overnight)
        XCTAssertEqual(result.data?.marketingEnabled, false)
    }
    func testFixedZoneAndOptOutAreExplicit() async {
        let service = await service()
        MockURLProtocol.requestHandler = { request in
            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["quiet_hours_follow_device"] as? Bool, false)
            XCTAssertEqual(body["quiet_hours_tz"] as? String, "Europe/London")
            XCTAssertEqual(body["quiet_hours_enabled"] as? Bool, false)
            return TestFixtures.envelopedResponse(json: self.preferences)
        }
        let result = await service.setQuietHours(PushQuietHours(enabled: false, timeZoneIdentifier: "Europe/London"))
        XCTAssertTrue(result.isSuccess)
    }
    func testInvalidScheduleDoesNotReachServer() async {
        let service = await service()
        MockURLProtocol.requestHandler = { _ in XCTFail("Invalid schedule must not be sent"); throw URLError(.badURL) }
        let result = await service.setQuietHours(PushQuietHours(startMinutes: 480, endMinutes: 480))
        XCTAssertFalse(result.isSuccess)
    }
}
#endif
