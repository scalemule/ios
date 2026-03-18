import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleAuth

final class AuthServiceRegisterTests: XCTestCase {
    func testRegisterReturnsUserOnly() async {
        let (app, _) = createTestClient()
        let auth = AuthService(client: app.client)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url?.path.contains("/v1/auth/register") ?? false)

            // Verify body
            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["email"] as? String, "test@example.com")
            XCTAssertEqual(body["password"] as? String, "password123")
            XCTAssertEqual(body["full_name"] as? String, "Test User")

            // No Authorization header
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

            return TestFixtures.envelopedResponse(json: TestFixtures.registerJSON)
        }

        let result = await auth.register(
            email: "test@example.com",
            password: "password123",
            name: "Test User"
        )

        let user = assertApiSuccess(result)
        XCTAssertEqual(user?.id, "usr_abc123")
        XCTAssertEqual(user?.email, "test@example.com")
        XCTAssertEqual(user?.status, "active")
    }
}
