import XCTest
@testable import ScaleMuleCore

final class ApiResponseTests: XCTestCase {
    func testSuccessResponse() {
        let response: ApiResponse<String> = .success("hello")
        XCTAssertTrue(response.isSuccess)
        XCTAssertEqual(response.data, "hello")
        XCTAssertNil(response.error)
    }

    func testFailureResponse() {
        let error = ApiError(code: .notFound, message: "Not found", statusCode: 404)
        let response: ApiResponse<String> = .failure(error)
        XCTAssertFalse(response.isSuccess)
        XCTAssertNil(response.data)
        XCTAssertEqual(response.error?.code, .notFound)
    }

    func testApiErrorEquality() {
        let a = ApiError(code: .unauthorized, message: "Unauthorized")
        let b = ApiError(code: .unauthorized, message: "Unauthorized")
        XCTAssertEqual(a, b)
    }

    func testApiErrorFactoryMethods() {
        let network = ApiError.network("Connection failed")
        XCTAssertEqual(network.code, .networkError)

        let timeout = ApiError.timeout()
        XCTAssertEqual(timeout.code, .timeout)

        let unauth = ApiError.unauthorized()
        XCTAssertEqual(unauth.code, .unauthorized)
        XCTAssertEqual(unauth.statusCode, 401)
    }
}
