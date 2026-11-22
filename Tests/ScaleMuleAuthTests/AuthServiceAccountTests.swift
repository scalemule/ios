import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleAuth

final class AuthServiceAccountTests: XCTestCase {
    func testUpdateProfileUpdatesAuthState() async {
        let (app, _) = createTestClient()
        try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600)))
        let auth = AuthService(app: app)
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url?.path, "/v1/auth/profile")
            XCTAssertEqual(self.bodyJSON(request)?["full_name"] as? String, "Sam Rivera")
            return TestFixtures.envelopedResponse(json: TestFixtures.userJSON.replacingOccurrences(of: "\"Test User\"", with: "\"Sam Rivera\""))
        }
        let user = assertApiSuccess(await auth.updateProfile(fullName: "Sam Rivera"))
        XCTAssertEqual(user?.fullName, "Sam Rivera")
        var iterator = await app.authStateStream().makeAsyncIterator()
        let state = await iterator.next()
        if case .authenticated(let current) = state {
            XCTAssertEqual(current.fullName, "Sam Rivera")
        } else {
            XCTFail("Expected authenticated state, got \(String(describing: state))")
        }
    }

    func testUpdateProfileWithNothingIsRefusedLocally() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        MockURLProtocol.requestHandler = { _ in
            XCTFail("No request expected")
            return TestFixtures.mockResponse(json: "{}")
        }
        let error = assertApiFailure(await auth.updateProfile())
        XCTAssertEqual(error?.code, .validationError)
    }

    func testDeleteAccountClearsSession() async {
        let (app, _) = createTestClient()
        try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600)))
        let auth = AuthService(app: app)
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/v1/auth/me")
            return TestFixtures.envelopedResponse(json: #"{"message":"Account deleted"}"#)
        }
        let result = await auth.deleteAccount()
        XCTAssertTrue(result.isSuccess)
        let signedIn = await app.isAuthenticated
        XCTAssertFalse(signedIn)
    }
}
