import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleAuth

final class AuthServiceLoginTests: XCTestCase {
    func testLoginSessionOnly() async {
        let (app, _) = createTestClient()
        let auth = AuthService(client: app.client)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["email"] as? String, "test@example.com")
            XCTAssertEqual(body["password"] as? String, "password123")

            return TestFixtures.envelopedResponse(json: TestFixtures.loginJSON)
        }

        let result = await auth.login(email: "test@example.com", password: "password123")

        let login = assertApiSuccess(result)
        XCTAssertEqual(login?.sessionToken, "sess_abc123")
        XCTAssertEqual(login?.user.id, "usr_abc123")
        XCTAssertNil(login?.accessToken)
        XCTAssertNil(login?.refreshToken)

        let creds = login?.toCredentialSet()
        XCTAssertEqual(creds?.authMode, .sessionOnly)
    }

    func testLoginWithRefreshTokens() async {
        let (app, _) = createTestClient()
        let auth = AuthService(client: app.client)

        MockURLProtocol.requestHandler = { _ in
            TestFixtures.envelopedResponse(json: TestFixtures.loginWithTokensJSON)
        }

        let result = await auth.login(email: "test@example.com", password: "password123")

        let login = assertApiSuccess(result)
        XCTAssertEqual(login?.accessToken, "at_jwt_123")
        XCTAssertEqual(login?.refreshToken, "rt_abc123")
        XCTAssertEqual(login?.accessTokenExpiresIn, 3600)

        let creds = login?.toCredentialSet()
        XCTAssertEqual(creds?.authMode, .refreshToken)
    }

    func testLoginWithMFAChallenge() async {
        let (app, _) = createTestClient()
        let auth = AuthService(client: app.client)

        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 202, json: TestFixtures.mfaChallengeJSON)
        }

        let result = await auth.login(email: "test@example.com", password: "password123")

        let error = assertApiFailure(result, code: .mfaRequired)
        XCTAssertEqual(error?.statusCode, 202)
    }
}
