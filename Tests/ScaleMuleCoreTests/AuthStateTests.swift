import XCTest
@testable import ScaleMuleCore

final class AuthStateTests: XCTestCase {
    func testAuthStatesAreEquatable() {
        XCTAssertEqual(AuthState.unknown, AuthState.unknown)
        XCTAssertEqual(AuthState.loading, AuthState.loading)
        XCTAssertEqual(AuthState.unauthenticated, AuthState.unauthenticated)
        XCTAssertNotEqual(AuthState.unknown, AuthState.loading)
    }

    func testAuthenticatedState() {
        let user = AuthUser(
            id: "usr_1",
            email: "test@example.com",
            phone: nil,
            username: "test",
            fullName: "Test",
            avatarUrl: nil,
            emailVerified: true,
            phoneVerified: false,
            mfaEnabled: false,
            createdAt: nil,
            updatedAt: nil
        )
        let state = AuthState.authenticated(user)
        if case .authenticated(let u) = state {
            XCTAssertEqual(u.id, "usr_1")
        } else {
            XCTFail("Expected authenticated state")
        }
    }

    func testMfaRequiredState() {
        let challenge = MFAChallenge(
            pendingToken: "mfa_123",
            mfaMethod: "totp",
            expiresIn: 600,
            allowedMethods: ["totp", "sms"]
        )
        let state = AuthState.mfaRequired(challenge)
        if case .mfaRequired(let c) = state {
            XCTAssertEqual(c.pendingToken, "mfa_123")
            XCTAssertEqual(c.allowedMethods.count, 2)
        } else {
            XCTFail("Expected mfaRequired state")
        }
    }

    func testMfaSetupRequiredState() {
        let req = MFASetupRequirement(
            message: "MFA is required",
            requirementSource: "customer_policy"
        )
        let state = AuthState.mfaSetupRequired(req)
        if case .mfaSetupRequired(let r) = state {
            XCTAssertEqual(r.requirementSource, "customer_policy")
        } else {
            XCTFail("Expected mfaSetupRequired state")
        }
    }
}
