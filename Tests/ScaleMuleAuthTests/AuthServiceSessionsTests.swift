import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleAuth

final class AuthServiceSessionsTests: XCTestCase {
    func testListSessions() async {
        let (app, _) = createTestClient()
        let auth = AuthService(client: app.client)

        let creds = CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600))
        try? await app.sessionManager.setCredentials(creds)

        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("sess_123") ?? false)
            return TestFixtures.mockResponse(json: TestFixtures.sessionsListJSON)
        }

        let result = await auth.sessions.list()

        let sessions = assertApiSuccess(result)
        XCTAssertEqual(sessions?.total, 1)
        XCTAssertEqual(sessions?.sessions.first?.id, "sess_1")
        XCTAssertEqual(sessions?.sessions.first?.isCurrent, true)
    }

    func testRevokeSession() async {
        let (app, _) = createTestClient()
        let auth = AuthService(client: app.client)

        let creds = CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600))
        try? await app.sessionManager.setCredentials(creds)

        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(json: """
            {"message": "Session revoked"}
            """)
        }

        let result = await auth.sessions.revoke(sessionId: "sess_other")
        let msg = assertApiSuccess(result)
        XCTAssertEqual(msg?.message, "Session revoked")
    }
}
