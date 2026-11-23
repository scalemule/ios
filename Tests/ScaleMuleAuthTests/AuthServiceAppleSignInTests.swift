import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleAuth
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

final class AuthServiceAppleSignInTests: XCTestCase {
    func testNonceIsRandomAndAppleGetsItsSha256() {
        let known = AppleSignInNonce(raw: "abc")
        XCTAssertEqual(known.hashed, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let a = AppleSignInNonce(), b = AppleSignInNonce()
        XCTAssertNotEqual(a.raw, b.raw)
        XCTAssertGreaterThanOrEqual(a.raw.count, 40)
        XCTAssertNil(a.raw.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")), "URL-safe")
        XCTAssertEqual(a.hashed.count, 64)
    }

    func testSendsAppleTokenAndNonceAndSignsIn() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        let nonce = AppleSignInNonce(raw: "nonce-1")
        var body: [String: Any]?
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.path.hasSuffix("/v1/auth/oauth/ledvery/apple-native"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "no session needed")
            body = self.bodyJSON(request)
            return TestFixtures.envelopedResponse(json: """
            {"session_token": "sess_apple", "user": \(TestFixtures.userJSON),
             "expires_at": "2026-12-21T00:00:00Z", "is_new_user": true, "is_new_link": false}
            """)
        }
        let result = await auth.completeAppleSignIn(
            identityToken: "eyJ.apple.jwt", nonce: nonce, authorizationCode: "c-1",
            givenName: " Плamen ", familyName: ""
        )
        guard case .signedIn(let user, let isNewUser)? = assertApiSuccess(result) else { return XCTFail("expected signedIn") }
        XCTAssertEqual(user.id, "usr_abc123")
        XCTAssertTrue(isNewUser)
        XCTAssertEqual(body?["identity_token"] as? String, "eyJ.apple.jwt")
        XCTAssertEqual(body?["raw_nonce"] as? String, "nonce-1", "the raw nonce goes to ScaleMule, the hash to Apple")
        XCTAssertEqual(body?["authorization_code"] as? String, "c-1")
        XCTAssertEqual(body?["given_name"] as? String, "Плamen")
        XCTAssertNil(body?["family_name"], "empty names are not sent")
        let token = await app.sessionManager.sessionToken
        XCTAssertEqual(token, "sess_apple")
    }

    func testEmailWithAnAccountAsksToLink() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 409, json: """
            {"success": false,
             "data": {"challenge_id": "01a1ff00-0000-7000-8000-000000000009", "email_hint": "p***@example.com",
                      "expires_at": "2026-11-23T23:00:00Z", "methods": ["password", "email_code"]},
             "error": {"code": "LINK_REQUIRED", "message": "An account with this email already exists."}}
            """)
        }
        let result = await auth.completeAppleSignIn(identityToken: "t", nonce: AppleSignInNonce())
        guard case .linkRequired(let challenge)? = assertApiSuccess(result) else { return XCTFail("expected linkRequired") }
        XCTAssertEqual(challenge.challengeId, "01a1ff00-0000-7000-8000-000000000009")
        XCTAssertEqual(challenge.methods, ["password", "email_code"])
        let token = await app.sessionManager.sessionToken
        XCTAssertNil(token)
    }

    func testRefusedTokenStaysSignedOut() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 401, json: #"{"success":false,"error":{"code":"APPLE_TOKEN_INVALID","message":"Sign in with Apple could not be verified."}}"#)
        }
        let result = await auth.completeAppleSignIn(identityToken: "forged", nonce: AppleSignInNonce())
        XCTAssertEqual(result.error?.rawCode, "APPLE_TOKEN_INVALID")
        let token = await app.sessionManager.sessionToken
        XCTAssertNil(token)
    }

    #if canImport(AuthenticationServices)
    func testClosedSheetIsACancel() {
        let cancelled = AuthService.appleSheetError(ASAuthorizationError(.canceled))
        XCTAssertEqual(cancelled.rawCode, AuthService.signInCancelledCode)
        let failed = AuthService.appleSheetError(ASAuthorizationError(.failed))
        XCTAssertNotEqual(failed.rawCode, AuthService.signInCancelledCode)
    }
    #endif
}
