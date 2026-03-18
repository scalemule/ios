import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore

final class HTTPClientTests: XCTestCase {
    func testSuccessfulRequest() async {
        let (app, _) = createTestClient()

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "pk_test_abc123")
            XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("ScaleMule-SDK-Swift") ?? false)
            return TestFixtures.envelopedResponse(json: TestFixtures.userJSON)
        }

        let result: ApiResponse<AuthUser> = await app.client.request(RequestOptions(
            method: .get,
            path: "/v1/auth/me",
            credential: .none
        ))

        let user = assertApiSuccess(result)
        XCTAssertEqual(user?.id, "usr_abc123")
        XCTAssertEqual(user?.email, "test@example.com")
    }

    func testErrorResponse() async {
        let (app, _) = createTestClient()

        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 401, json: """
            {"code": "UNAUTHORIZED", "message": "Invalid session"}
            """)
        }

        let result: ApiResponse<AuthUser> = await app.client.request(RequestOptions(
            method: .get,
            path: "/v1/auth/me",
            credential: .none
        ))

        let error = assertApiFailure(result, code: .unauthorized)
        XCTAssertEqual(error?.message, "Invalid session")
    }

    func test204NoContent() async {
        let (app, _) = createTestClient()

        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.scalemule.com")!,
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let result = await app.client.requestVoid(RequestOptions(
            method: .delete,
            path: "/v1/workspaces/ws_1",
            credential: .none
        ))

        XCTAssertTrue(result.isSuccess)
    }

    func testMFAChallengeResponse() async {
        let (app, _) = createTestClient()

        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 202, json: TestFixtures.mfaChallengeJSON)
        }

        let result: ApiResponse<AuthUser> = await app.client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/login",
            credential: .none
        ))

        let error = assertApiFailure(result, code: .mfaRequired)
        XCTAssertNotNil(error?.details?["pending_token"])
    }
}
