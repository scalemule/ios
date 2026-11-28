import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleAuth

final class AuthServiceLedveryEmailTests: XCTestCase {
    private func refusal(_ status: Int, _ code: String, _ message: String) -> (HTTPURLResponse, Data) {
        TestFixtures.mockResponse(statusCode: status, json: """
        {"success": false, "error": {"code": "\(code)", "message": "\(message)"}}
        """)
    }

    func testCreatingAnAccountSendsTheFormAndSignsNobodyIn() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        var body: [String: Any]?
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.path.hasSuffix("/v1/auth/oauth/ledvery/email-native/register"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "no session needed")
            body = self.bodyJSON(request)
            return TestFixtures.envelopedResponse(json: """
            {"email": "reader@example.com", "verification_required": true, "verification_method": "otp_code"}
            """)
        }
        let result = await auth.registerLedveryEmailAccount(
            email: "  Reader@Example.com ", password: " пароль 😀 ", name: " Пламен 山田 "
        )
        let created = assertApiSuccess(result)
        XCTAssertEqual(created?.email, "reader@example.com")
        XCTAssertEqual(created?.verificationRequired, true)
        XCTAssertEqual(created?.verificationMethod, "otp_code")
        XCTAssertEqual(body?["email"] as? String, "Reader@Example.com", "trimmed")
        XCTAssertEqual(body?["password"] as? String, " пароль 😀 ", "a password is sent exactly as typed")
        XCTAssertEqual(body?["full_name"] as? String, "Пламен 山田")
        let token = await app.sessionManager.sessionToken
        XCTAssertNil(token)
    }

    func testAnEmptyNameIsNotSent() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        var body: [String: Any]?
        MockURLProtocol.requestHandler = { request in
            body = self.bodyJSON(request)
            return TestFixtures.envelopedResponse(json: """
            {"email": "a@example.com", "verification_required": true, "verification_method": "otp_code"}
            """)
        }
        _ = await auth.registerLedveryEmailAccount(email: "a@example.com", password: "pw", name: "   ")
        XCTAssertNil(body?["full_name"])
    }

    func testConfirmingSendsTheCodeWithoutSpaces() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        var body: [String: Any]?
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.path.hasSuffix("/v1/auth/oauth/ledvery/email-native/verify"))
            body = self.bodyJSON(request)
            return TestFixtures.envelopedResponse(json: #"{"verified": true}"#)
        }
        let result = await auth.confirmLedveryEmail(email: " reader@example.com", code: " 123 456\n")
        XCTAssertEqual(assertApiSuccess(result), true)
        XCTAssertEqual(body?["email"] as? String, "reader@example.com")
        XCTAssertEqual(body?["code"] as? String, "123456")
    }

    func testAWrongCodeIsARefusalWithItsSentence() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        MockURLProtocol.requestHandler = { _ in
            self.refusal(400, "VERIFICATION_CODE_INVALID", "That code is not right or has expired.")
        }
        let result = await auth.confirmLedveryEmail(email: "reader@example.com", code: "000000")
        XCTAssertEqual(result.error?.rawCode, AuthService.verificationCodeInvalidCode)
        XCTAssertEqual(result.error?.message, "That code is not right or has expired.")
    }

    func testResendAndPasswordResetUseTheirRoutes() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        var paths: [String] = []
        MockURLProtocol.requestHandler = { request in
            paths.append(request.url!.path)
            XCTAssertEqual(self.bodyJSON(request)?["email"] as? String, "reader@example.com")
            return TestFixtures.envelopedResponse(json: #"{"message": "Sent."}"#)
        }
        let resent = await auth.resendLedveryEmailCode(email: "reader@example.com ")
        XCTAssertEqual(assertApiSuccess(resent)?.message, "Sent.")
        let reset = await auth.sendLedveryPasswordReset(email: " reader@example.com")
        XCTAssertEqual(assertApiSuccess(reset)?.message, "Sent.")
        XCTAssertTrue(paths[0].hasSuffix("/v1/auth/oauth/ledvery/email-native/resend"))
        XCTAssertTrue(paths[1].hasSuffix("/v1/auth/oauth/ledvery/email-native/forgot"))
    }

    func testSigningInStoresTheSession() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        var body: [String: Any]?
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.path.hasSuffix("/v1/auth/oauth/ledvery/email-native/login"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            body = self.bodyJSON(request)
            return TestFixtures.envelopedResponse(json: """
            {"session_token": "sess_email", "user": \(TestFixtures.userJSON),
             "expires_at": "2026-12-27T00:00:00Z", "is_new_user": true, "is_new_link": false}
            """)
        }
        let result = await auth.signInWithLedveryEmail(email: " reader@example.com ", password: "pw 😀")
        guard case .signedIn(let user, let isNewUser)? = assertApiSuccess(result) else { return XCTFail("expected signedIn") }
        XCTAssertEqual(user.id, "usr_abc123")
        XCTAssertTrue(isNewUser)
        XCTAssertEqual(body?["email"] as? String, "reader@example.com")
        XCTAssertEqual(body?["password"] as? String, "pw 😀")
        XCTAssertNil(body?["mfa_code"])
        let token = await app.sessionManager.sessionToken
        XCTAssertEqual(token, "sess_email")
    }

    func testAWrongPasswordStaysSignedOutWithTheNeutralSentence() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        MockURLProtocol.requestHandler = { _ in
            self.refusal(401, "INVALID_CREDENTIALS", "That email or password is not right.")
        }
        let result = await auth.signInWithLedveryEmail(email: "reader@example.com", password: "wrong")
        XCTAssertEqual(result.error?.rawCode, AuthService.invalidCredentialsCode)
        XCTAssertEqual(result.error?.message, "That email or password is not right.")
        let token = await app.sessionManager.sessionToken
        XCTAssertNil(token)
    }

    func testAnUnconfirmedAddressLeadsToTheCodeScreen() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        MockURLProtocol.requestHandler = { _ in
            self.refusal(403, "EMAIL_NOT_VERIFIED", "Confirm your email address to finish signing in.")
        }
        let result = await auth.signInWithLedveryEmail(email: "reader@example.com", password: "pw")
        XCTAssertEqual(assertApiSuccess(result), .emailConfirmationRequired(message: "Confirm your email address to finish signing in."))
    }

    func testTwoStepSignInAsksForTheCodeAndSendsIt() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        var bodies: [[String: Any]] = []
        MockURLProtocol.requestHandler = { request in
            let body = self.bodyJSON(request) ?? [:]
            bodies.append(body)
            if body["mfa_code"] == nil {
                return self.refusal(401, "MFA_CODE_REQUIRED", "Enter the code from your authenticator app.")
            }
            return TestFixtures.envelopedResponse(json: """
            {"session_token": "sess_mfa", "user": \(TestFixtures.userJSON),
             "expires_at": "2026-12-27T00:00:00Z", "is_new_user": false, "is_new_link": false}
            """)
        }
        let first = await auth.signInWithLedveryEmail(email: "reader@example.com", password: "pw")
        XCTAssertEqual(assertApiSuccess(first), .mfaCodeRequired(message: "Enter the code from your authenticator app."))
        let second = await auth.signInWithLedveryEmail(email: "reader@example.com", password: "pw", mfaCode: " 654321 ")
        guard case .signedIn? = assertApiSuccess(second) else { return XCTFail("expected signedIn") }
        XCTAssertEqual(bodies.last?["mfa_code"] as? String, "654321")
    }

    func testAnOlderAppAccountWithThatEmailAsksToLink() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 409, json: """
            {"success": false,
             "data": {"challenge_id": "01a1ff00-0000-7000-8000-000000000009", "email_hint": "r***@example.com",
                      "expires_at": "2026-11-27T23:00:00Z", "methods": ["password"]},
             "error": {"code": "LINK_REQUIRED", "message": "An account with this email already exists."}}
            """)
        }
        let result = await auth.signInWithLedveryEmail(email: "reader@example.com", password: "pw")
        guard case .linkRequired(let challenge)? = assertApiSuccess(result) else { return XCTFail("expected linkRequired") }
        XCTAssertEqual(challenge.challengeId, "01a1ff00-0000-7000-8000-000000000009")
        let token = await app.sessionManager.sessionToken
        XCTAssertNil(token)
    }

    func testAnAppWithoutTheFeatureGetsItsOwnCode() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        MockURLProtocol.requestHandler = { _ in
            self.refusal(403, "NATIVE_EMAIL_NOT_ENABLED", "Email sign-in inside the app is not enabled for this application.")
        }
        let result = await auth.registerLedveryEmailAccount(email: "reader@example.com", password: "pw")
        XCTAssertEqual(result.error?.rawCode, AuthService.nativeEmailNotEnabledCode)
    }
}
