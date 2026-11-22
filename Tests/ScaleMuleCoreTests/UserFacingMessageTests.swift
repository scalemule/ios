import XCTest
@testable import ScaleMuleCore

final class UserFacingMessageTests: XCTestCase {
    func testServerFailureNeverSaysInternalError() {
        let error = ApiError(code: .internalError, message: "An internal error occurred", statusCode: 500, rawCode: "INTERNAL_ERROR")
        XCTAssertEqual(error.userFacingMessage, "Something went wrong on our side. Please try again in a minute.")
        XCTAssertEqual(error.localizedDescription, error.userFacingMessage)
        XCTAssertFalse(error.userFacingMessage.localizedCaseInsensitiveContains("internal"))
    }

    func testUnmappedServerCodeWith5xx() {
        let error = ApiError(code: .unknown, message: "Database error: pool timed out", statusCode: 503, rawCode: "DATABASE_ERROR")
        XCTAssertEqual(error.userFacingMessage, "Something went wrong on our side. Please try again in a minute.")
    }

    func testDecodeFailureWithoutStatus() {
        let error = ApiError(code: .internalError, message: "Failed to decode response: keyNotFound")
        XCTAssertEqual(error.userFacingMessage, "Something went wrong on our side. Please try again in a minute.")
    }

    func testTrustRefusalExplainsWhatToDo() {
        let error = ApiError(code: .forbidden, message: "Your request has been blocked due to suspicious activity.", statusCode: 403, rawCode: "TRUST_SCORE_TOO_LOW")
        XCTAssertTrue(error.userFacingMessage.contains("Wi-Fi and mobile data"))
    }

    func testNetworkTimeoutAndRateLimit() {
        XCTAssertTrue(ApiError.network("The Internet connection appears to be offline.").userFacingMessage.contains("offline"))
        XCTAssertTrue(ApiError.timeout().userFacingMessage.contains("too long"))
        XCTAssertTrue(ApiError(code: .rateLimited, message: "Rate limited", statusCode: 429).userFacingMessage.contains("Too many tries"))
    }

    func testClientErrorsKeepServerWording() {
        let wrong = ApiError(code: .unauthorized, message: "Invalid email or password", statusCode: 401, rawCode: "UNAUTHORIZED")
        XCTAssertEqual(wrong.userFacingMessage, "Invalid email or password")
        let blank = ApiError(code: .validationError, message: "  ", statusCode: 422)
        XCTAssertEqual(blank.userFacingMessage, "Something went wrong. Please try again.")
    }
}
