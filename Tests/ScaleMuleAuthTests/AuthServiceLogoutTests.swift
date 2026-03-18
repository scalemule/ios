import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleAuth

final class AuthServiceLogoutTests: XCTestCase {
    func testLogoutSendsSessionTokenInBody() async {
        let (app, _) = createTestClient()
        let auth = AuthService(client: app.client)

        // Set up session first
        let creds = CredentialSet(
            sessionToken: "sess_test_123",
            sessionExpiresAt: Date().addingTimeInterval(3600)
        )
        try? await app.sessionManager.setCredentials(creds)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")

            // Verify session_token is in the body (sessionBody strategy)
            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["session_token"] as? String, "sess_test_123")

            return TestFixtures.mockResponse(json: "{}")
        }

        let result = await auth.logout()
        XCTAssertTrue(result.isSuccess)
    }
}
