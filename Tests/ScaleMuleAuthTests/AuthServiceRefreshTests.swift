import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleAuth

final class AuthServiceRefreshTests: XCTestCase {
    func testRefreshSessionSendsTokenInBody() async {
        let (app, _) = createTestClient()
        let auth = AuthService(client: app.client)

        let creds = CredentialSet(
            sessionToken: "sess_to_refresh",
            sessionExpiresAt: Date().addingTimeInterval(3600)
        )
        try? await app.sessionManager.setCredentials(creds)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url?.path.contains("/v1/auth/refresh") ?? false)

            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["session_token"] as? String, "sess_to_refresh")

            return TestFixtures.envelopedResponse(json: TestFixtures.refreshSessionJSON)
        }

        let result = await auth.refreshSession()

        let refresh = assertApiSuccess(result)
        XCTAssertEqual(refresh?.sessionToken, "sess_refreshed_456")
        XCTAssertNotNil(refresh?.expiresAt)
    }

    func testRefreshAccessToken() async {
        let (app, _) = createTestClient()
        let auth = AuthService(client: app.client)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url?.path.contains("/v1/auth/token/refresh") ?? false)

            // No Authorization header
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["refresh_token"] as? String, "rt_abc123")

            return TestFixtures.envelopedResponse(json: """
            {"access_token": "at_new_jwt", "token_type": "Bearer", "expires_in": 3600}
            """)
        }

        let result = await auth.refreshAccessToken(refreshToken: "rt_abc123")

        let refresh = assertApiSuccess(result)
        XCTAssertEqual(refresh?.accessToken, "at_new_jwt")
        XCTAssertEqual(refresh?.tokenType, "Bearer")
        XCTAssertEqual(refresh?.expiresIn, 3600)
    }
}
