#if canImport(UIKit)
import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMulePush

@MainActor private final class TestPushSystem: PushSystem {
    var status: PushPermission = .notDetermined
    var requestCalls = 0
    var registrations = 0
    var unregistrations = 0
    var badges: [Int] = []
    func permission() async -> PushPermission { status }
    func requestPermission() async throws -> Bool { requestCalls += 1; status = .authorized; return true }
    func register() { registrations += 1 }
    func unregister() { unregistrations += 1 }
    func removeDeliveredNotifications() {}
    func setBadge(_ count: Int) async throws { badges.append(count) }
}

@MainActor final class PushNotificationsTests: XCTestCase {
    private func makePush(_ system: TestPushSystem) -> PushNotifications {
        let (app, _) = createTestClient()
        return PushNotifications(app: app, system: system,
            defaults: UserDefaults(suiteName: "push-tests-\(UUID().uuidString)")!)
    }

    func testRefreshNeverPromptsOrRegistersWithoutOptInAndSignIn() async {
        let system = TestPushSystem()
        let push = makePush(system)
        await push.refresh()
        XCTAssertEqual(system.requestCalls, 0)
        XCTAssertEqual(system.registrations, 0)
        XCTAssertFalse(push.isEnabled)
        XCTAssertFalse(push.isRegistered)
    }

    func testExplicitPermissionRequestsThenRevokedPermissionDoesNotReprompt() async {
        let system = TestPushSystem()
        let push = makePush(system)
        let granted = await push.requestAuthorization()
        XCTAssertTrue(granted)
        XCTAssertTrue(push.isEnabled)
        XCTAssertEqual(system.requestCalls, 1)
        XCTAssertEqual(system.registrations, 0) // Still not signed in.
        system.status = .denied
        await push.refresh()
        XCTAssertEqual(push.permission, .denied)
        XCTAssertEqual(system.requestCalls, 1)
        XCTAssertFalse(push.isRegistered)
    }

    func testDisableAndSignOutUnregisterTheOSAndClearBadge() async {
        let system = TestPushSystem()
        let push = makePush(system)
        _ = await push.requestAuthorization()
        await push.setEnabled(false)
        XCTAssertFalse(push.isEnabled)
        XCTAssertEqual(system.badges.last, 0)
        let count = system.unregistrations
        await push.deactivateBeforeSignOut()
        XCTAssertGreaterThan(system.unregistrations, count)
        XCTAssertFalse(push.isRegistered)
    }

    func testAnUnsolicitedTokenCallbackDoesNotRegisterAnAnonymousDevice() async {
        let system = TestPushSystem()
        let push = makePush(system)
        push.didRegister(deviceToken: Data([0, 1, 255]))
        await Task.yield()
        XCTAssertFalse(push.isRegistered)
        XCTAssertFalse(push.isWorking)
        XCTAssertNil(push.lastError)
    }

    func testAnotherAccountsNotificationCannotOpenTheCurrentAccount() {
        XCTAssertFalse(PushNotifications.matchesRecipient(["recipient_user_id": "other"], userId: "me"))
        XCTAssertFalse(PushNotifications.matchesRecipient(["recipient_user_id": 42], userId: "me"))
        XCTAssertTrue(PushNotifications.matchesRecipient(["recipient_user_id": "me"], userId: "me"))
        XCTAssertTrue(PushNotifications.matchesRecipient(["post_id": "p1"], userId: "me"))
    }
}
#endif
