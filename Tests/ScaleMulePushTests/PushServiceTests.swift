import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMulePush

// HTTP contract tests run on macOS, where the package test process can use
// Keychain. iOS lifecycle tests below use an injected notification system;
// SwiftPM's unhosted iOS xctest process has no app Keychain access group.
#if os(macOS)
final class PushServiceTests: XCTestCase {
    private let id = "019b0000-0000-7000-8000-000000000001"
    private let user = "019b0000-0000-7000-8000-000000000002"

    private func signedIn() async -> ScaleMuleApp {
        let (app, _) = createTestClient()
        try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "session-for-current-user",
            accessToken: "different-jwt", sessionExpiresAt: Date().addingTimeInterval(3600)))
        return app
    }

    func testTokenEncodingPreservesAllBytesAndVariableLengths() {
        XCTAssertEqual(PushService.tokenString(Data([0, 1, 15, 16, 255])), "00010f10ff")
        XCTAssertEqual(PushService.tokenString(Data(repeating: 0xab, count: 64)).count, 128)
    }

    func testRegistrationIsSessionBoundAndNeverClaimsAnOwnerInTheBody() async {
        let app = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/communication/push/register")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-for-current-user")
            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["token"] as? String, "0001ff")
            XCTAssertEqual(body["platform"] as? String, "ios")
            XCTAssertNil(body["device_account_user_ids"])
            XCTAssertNil(body["user_id"])
            XCTAssertNil(body["device_id"])
            return TestFixtures.envelopedResponse(json: """
            {"id":"\(self.id)","user_id":"\(self.user)","platform":"ios","is_active":true,"notifications_enabled":true}
            """)
        }
        let result = assertApiSuccess(await PushService(app: app).register(deviceToken: Data([0, 1, 255]), userId: user))
        XCTAssertEqual(result?.id, id)
        XCTAssertEqual(result?.notificationsEnabled, true)
    }

    func testNoAnonymousRegistrationOrEmptyTokenRequest() async {
        let (app, _) = createTestClient()
        MockURLProtocol.requestHandler = { _ in XCTFail("Must not send an anonymous push registration"); throw URLError(.badURL) }
        let unsigned = await PushService(app: app).register(deviceToken: Data([1]), userId: user)
        XCTAssertEqual(unsigned.error?.statusCode, 401)
        let signed = await signedIn()
        let empty = await PushService(app: signed).register(deviceToken: Data(), userId: user)
        XCTAssertFalse(empty.isSuccess)
    }

    func testUnregisterUsesStableIdAndOriginalSessionForAccountCleanup() async {
        let app = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/v1/communication/push/tokens/by-id/\(self.id)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old-session")
            return TestFixtures.mockResponse(statusCode: 204, json: "")
        }
        let result = await PushService(app: app).unregister(id: id, session: "old-session")
        XCTAssertTrue(result.isSuccess)
    }

    func testMissingRegistrationCleanupIsIdempotentAndBadIdNeverSent() async {
        let app = await signedIn()
        MockURLProtocol.requestHandler = { _ in TestFixtures.mockResponse(statusCode: 404, json: "{}") }
        let missing = await PushService(app: app).unregister(id: id)
        XCTAssertTrue(missing.isSuccess)
        MockURLProtocol.requestHandler = { _ in XCTFail("Invalid path identifier must not reach the server"); throw URLError(.badURL) }
        let invalid = await PushService(app: app).unregister(id: "../other-token")
        XCTAssertFalse(invalid.isSuccess)
    }

    func testExplicitOptInReenablesServerDevicePreference() async {
        let app = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/v1/communication/push/tokens/by-id/\(self.id)/notifications")
            XCTAssertEqual(self.bodyJSON(request)?["enabled"] as? Bool, true)
            return TestFixtures.envelopedResponse(json: "{\"enabled\":true}")
        }
        let result = await PushService(app: app).setEnabled(true, id: id, session: "session")
        XCTAssertTrue(result.isSuccess)
    }

    func testAnAccountChangeDuringRegistrationCleansUpUsingTheOriginalSession() async {
        let app = await signedIn()
        var methods: [String] = []
        MockURLProtocol.requestHandler = { request in
            methods.append(request.httpMethod!)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-for-current-user")
            if request.httpMethod == "DELETE" { return TestFixtures.mockResponse(statusCode: 204, json: "") }
            return TestFixtures.envelopedResponse(json: """
            {"id":"\(self.id)","user_id":"019b0000-0000-7000-8000-000000000003","platform":"ios","is_active":true,"notifications_enabled":true}
            """)
        }
        let result = await PushService(app: app).register(deviceToken: Data([1]), userId: user)
        XCTAssertEqual(result.error?.statusCode, 403)
        XCTAssertEqual(methods, ["POST", "DELETE"])
    }
}
#endif
