import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleAuth

final class AuthServiceLoginHistoryTests: XCTestCase {
    func testListLoginHistory() async {
        let (app, _) = createTestClient()
        let auth = AuthService(client: app.client)

        let creds = CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600))
        try? await app.sessionManager.setCredentials(creds)

        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            XCTAssertTrue(url.path.contains("/v1/auth/login-history"))
            return TestFixtures.mockResponse(json: TestFixtures.loginHistoryJSON)
        }

        let result = await auth.loginHistory.list(page: 1, perPage: 20)

        let history = assertApiSuccess(result)
        XCTAssertEqual(history?.total, 1)
        XCTAssertEqual(history?.page, 1)
        XCTAssertEqual(history?.perPage, 20)
        XCTAssertEqual(history?.entries.first?.success, true)
    }

    func testGetLoginSummary() async {
        let (app, _) = createTestClient()
        let auth = AuthService(client: app.client)

        let creds = CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600))
        try? await app.sessionManager.setCredentials(creds)

        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(json: """
            {
                "total_logins": 50,
                "successful_logins": 48,
                "failed_logins": 2,
                "unique_ips": 3,
                "unique_devices": 2,
                "last_login_at": "2026-01-15T10:00:00Z",
                "last_failed_at": "2026-01-10T08:00:00Z"
            }
            """)
        }

        let result = await auth.loginHistory.getSummary()
        let summary = assertApiSuccess(result)
        XCTAssertEqual(summary?.totalLogins, 50)
        XCTAssertEqual(summary?.failedLogins, 2)
    }
}
