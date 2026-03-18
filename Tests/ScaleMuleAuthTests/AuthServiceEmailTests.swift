import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleAuth

final class AuthServiceEmailTests: XCTestCase {
    func testVerifyEmailWithAutoSession() async {
        let (app, _) = createTestClient()
        let auth = AuthService(client: app.client)

        MockURLProtocol.requestHandler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["token"] as? String, "verify_token_123")

            return TestFixtures.envelopedResponse(json: TestFixtures.verifyEmailJSON)
        }

        let result = await auth.verifyEmail(token: "verify_token_123")

        let verify = assertApiSuccess(result)
        XCTAssertTrue(verify?.verified ?? false)
        XCTAssertNotNil(verify?.sessionToken)
        XCTAssertNotNil(verify?.user)

        // Auto-session creates sessionOnly CredentialSet
        let creds = verify?.toCredentialSet()
        XCTAssertNotNil(creds)
        XCTAssertEqual(creds?.authMode, .sessionOnly)
    }

    func testVerifyEmailWithoutAutoSession() async {
        let (app, _) = createTestClient()
        let auth = AuthService(client: app.client)

        MockURLProtocol.requestHandler = { _ in
            TestFixtures.envelopedResponse(json: """
            {"verified": true, "session_token": null, "user": null, "expires_at": null}
            """)
        }

        let result = await auth.verifyEmail(token: "verify_token_123")

        let verify = assertApiSuccess(result)
        XCTAssertTrue(verify?.verified ?? false)
        XCTAssertNil(verify?.sessionToken)
        XCTAssertNil(verify?.toCredentialSet())
    }

    func testResendVerification() async {
        let (app, _) = createTestClient()
        let auth = AuthService(client: app.client)

        MockURLProtocol.requestHandler = { _ in
            TestFixtures.envelopedResponse(json: TestFixtures.messageJSON)
        }

        let result = await auth.resendVerification(email: "test@example.com")
        let msg = assertApiSuccess(result)
        XCTAssertEqual(msg?.message, "Success")
    }
}
