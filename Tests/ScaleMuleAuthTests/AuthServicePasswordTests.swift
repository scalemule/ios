import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleAuth

final class AuthServicePasswordTests: XCTestCase {
    func testForgotPassword() async {
        let (app, _) = createTestClient()
        let auth = AuthService(client: app.client)

        MockURLProtocol.requestHandler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return TestFixtures.mockResponse(json: TestFixtures.messageJSON)
        }

        let result = await auth.forgotPassword(email: "test@example.com")
        XCTAssertTrue(result.isSuccess)
    }

    func testResetPassword() async {
        let (app, _) = createTestClient()
        let auth = AuthService(client: app.client)

        MockURLProtocol.requestHandler = { request in
            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["token"] as? String, "reset_token")
            XCTAssertEqual(body["new_password"] as? String, "newpass123")
            return TestFixtures.mockResponse(json: TestFixtures.messageJSON)
        }

        let result = await auth.resetPassword(token: "reset_token", newPassword: "newpass123")
        XCTAssertTrue(result.isSuccess)
    }

    func testChangePassword() async {
        let (app, _) = createTestClient()
        let auth = AuthService(client: app.client)

        let creds = CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600))
        try? await app.sessionManager.setCredentials(creds)

        MockURLProtocol.requestHandler = { request in
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
            return TestFixtures.mockResponse(json: TestFixtures.messageJSON)
        }

        let result = await auth.changePassword(currentPassword: "oldpass", newPassword: "newpass")
        XCTAssertTrue(result.isSuccess)
    }
}
