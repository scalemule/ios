import XCTest
@testable import ScaleMuleCore

final class CredentialsTests: XCTestCase {
    func testSessionOnlyMode() {
        let creds = CredentialSet(
            sessionToken: "sess_123",
            sessionExpiresAt: Date().addingTimeInterval(3600)
        )
        XCTAssertEqual(creds.authMode, .sessionOnly)
        XCTAssertNil(creds.accessToken)
        XCTAssertNil(creds.refreshToken)
    }

    func testRefreshTokenMode() {
        let creds = CredentialSet(
            sessionToken: "sess_123",
            accessToken: "at_123",
            refreshToken: "rt_123",
            sessionExpiresAt: Date().addingTimeInterval(3600),
            accessTokenExpiresAt: Date().addingTimeInterval(1800)
        )
        XCTAssertEqual(creds.authMode, .refreshToken)
        XCTAssertNotNil(creds.accessToken)
        XCTAssertNotNil(creds.refreshToken)
    }

    func testWithUpdatedAccessToken() {
        let creds = CredentialSet(
            sessionToken: "sess_123",
            accessToken: "at_old",
            refreshToken: "rt_123",
            sessionExpiresAt: Date().addingTimeInterval(3600)
        )
        let newExpiry = Date().addingTimeInterval(1800)
        let updated = creds.withUpdatedAccessToken("at_new", expiresAt: newExpiry)
        XCTAssertEqual(updated.accessToken, "at_new")
        XCTAssertEqual(updated.sessionToken, "sess_123")
        XCTAssertEqual(updated.refreshToken, "rt_123")
    }

    func testWithRefreshedSession() {
        let creds = CredentialSet(
            sessionToken: "sess_old",
            sessionExpiresAt: Date().addingTimeInterval(3600)
        )
        let newExpiry = Date().addingTimeInterval(7200)
        let updated = creds.withRefreshedSession("sess_new", expiresAt: newExpiry)
        XCTAssertEqual(updated.sessionToken, "sess_new")
        XCTAssertEqual(updated.sessionExpiresAt, newExpiry)
    }
}
