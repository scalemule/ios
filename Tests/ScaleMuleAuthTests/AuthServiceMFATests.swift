import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleAuth

final class AuthServiceMFATests: XCTestCase {
    func testMfaVerifyWithPendingToken() async {
        let (app, _) = createTestClient()
        let auth = AuthService(client: app.client)

        MockURLProtocol.requestHandler = { request in
            // MFA verify uses .none credential — no Authorization header
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["pending_token"] as? String, "mfa_pending_abc")
            XCTAssertEqual(body["code"] as? String, "123456")

            return TestFixtures.envelopedResponse(json: TestFixtures.mfaVerifyJSON)
        }

        let result = await auth.mfa.verify(pendingToken: "mfa_pending_abc", code: "123456")

        let verify = assertApiSuccess(result)
        XCTAssertNotNil(verify?.sessionToken)
        XCTAssertNotNil(verify?.toCredentialSet())
    }

    func testMfaSendCode() async {
        let (app, _) = createTestClient()
        let auth = AuthService(client: app.client)

        MockURLProtocol.requestHandler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["pending_token"] as? String, "mfa_pending_abc")
            XCTAssertEqual(body["method"] as? String, "sms")

            return TestFixtures.envelopedResponse(json: """
            {"message": "Code sent", "expires_in": 300}
            """)
        }

        let result = await auth.mfa.sendCode(pendingToken: "mfa_pending_abc", method: .sms)
        let sendResult = assertApiSuccess(result)
        XCTAssertEqual(sendResult?.message, "Code sent")
    }

    func testGetMfaStatus() async {
        let (app, _) = createTestClient()
        let auth = AuthService(client: app.client)

        let creds = CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600))
        try? await app.sessionManager.setCredentials(creds)

        MockURLProtocol.requestHandler = { request in
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
            return TestFixtures.envelopedResponse(json: """
            {"enabled": true, "methods": ["totp"], "backup_codes_remaining": 8}
            """)
        }

        let result = await auth.mfa.getStatus()
        let status = assertApiSuccess(result)
        XCTAssertTrue(status?.enabled ?? false)
        XCTAssertEqual(status?.methods, ["totp"])
    }
}
