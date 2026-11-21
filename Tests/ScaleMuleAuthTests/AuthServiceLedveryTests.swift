import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleAuth

final class AuthServiceLedveryTests: XCTestCase {
    private let callback = "firehosy://oauth/ledvery/callback"

    private func queryItems(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testStartSendsCallbackAndUpstreamWithoutSession() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(request.url!.path.hasSuffix("/v1/auth/oauth/ledvery/authorize"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "pk_test_abc123")
            let query = self.queryItems(request)
            XCTAssertEqual(query["redirect_uri"], self.callback)
            XCTAssertEqual(query["upstream"], "google")
            XCTAssertNil(query["prompt"])
            return TestFixtures.envelopedResponse(json: """
            {"url": "https://api.ledvery.com/authorize?client_id=firehosy-ios&upstream=google", "state": "st.sig"}
            """)
        }

        let result = await auth.startLedverySignIn(redirectUri: callback, upstream: .google)
        let start = assertApiSuccess(result)
        XCTAssertEqual(start?.url.host, "api.ledvery.com")
        XCTAssertEqual(start?.state, "st.sig")
    }

    func testEmailUpstreamUsesConsumerProviderName() {
        XCTAssertEqual(LedveryUpstream.email.rawValue, "scalemule_consumer")
    }

    func testCompleteExchangesCodeAndSignsIn() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)

        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.path.hasSuffix("/v1/auth/oauth/ledvery/callback"))
            let query = self.queryItems(request)
            XCTAssertEqual(query["code"], "code-123")
            XCTAssertEqual(query["state"], "st.sig")
            return TestFixtures.envelopedResponse(json: """
            {"session_token": "sess_ledvery", "user": \(TestFixtures.userJSON),
             "expires_at": "2026-12-21T00:00:00Z", "is_new_user": true, "is_new_link": false}
            """)
        }

        let url = URL(string: "\(callback)?code=code-123&state=st.sig")!
        let result = await auth.completeLedverySignIn(callbackURL: url)
        guard case .signedIn(let user, let isNewUser)? = assertApiSuccess(result) else {
            return XCTFail("expected signedIn")
        }
        XCTAssertEqual(user.id, "usr_abc123")
        XCTAssertTrue(isNewUser)

        let token = await app.sessionManager.sessionToken
        XCTAssertEqual(token, "sess_ledvery")
        let state = await app.authState.state
        XCTAssertEqual(state, .authenticated(user))
    }

    func testCompleteMapsLinkRequired() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)

        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 409, json: """
            {"success": false,
             "data": {"challenge_id": "01a1ff00-0000-7000-8000-000000000001", "email_hint": "p***@example.com",
                      "expires_at": "2026-11-21T19:00:00Z", "methods": ["password"]},
             "error": {"code": "LINK_REQUIRED", "message": "An account with this email already exists."}}
            """)
        }

        let url = URL(string: "\(callback)?code=code-123&state=st.sig")!
        let result = await auth.completeLedverySignIn(callbackURL: url)
        guard case .linkRequired(let challenge)? = assertApiSuccess(result) else {
            return XCTFail("expected linkRequired")
        }
        XCTAssertEqual(challenge.challengeId, "01a1ff00-0000-7000-8000-000000000001")
        XCTAssertEqual(challenge.emailHint, "p***@example.com")
        XCTAssertEqual(challenge.methods, ["password"])
        let token = await app.sessionManager.sessionToken
        XCTAssertNil(token)
    }

    func testCompleteReportsRefusalWithoutCallingServer() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        MockURLProtocol.requestHandler = { _ in
            XCTFail("no request expected")
            return TestFixtures.envelopedResponse(json: "{}")
        }

        let url = URL(string: "\(callback)?error=access_denied&state=st.sig")!
        let result = await auth.completeLedverySignIn(callbackURL: url)
        let error = assertApiFailure(result)
        XCTAssertEqual(error?.rawCode, AuthService.signInCancelledCode)
    }

    func testCompleteWithoutCodeFails() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        let result = await auth.completeLedverySignIn(callbackURL: URL(string: callback)!)
        XCTAssertEqual(assertApiFailure(result)?.code, .validationError)
    }

    func testCompleteKeepsServerErrorCode() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 403, json: """
            {"success": false, "error": {"code": "JIT_DISABLED", "message": "Sign-up is closed for this app."}}
            """)
        }
        let url = URL(string: "\(callback)?code=c&state=s")!
        let error = assertApiFailure(await auth.completeLedverySignIn(callbackURL: url))
        XCTAssertEqual(error?.rawCode, "JIT_DISABLED")
        XCTAssertEqual(error?.code, .forbidden)
        XCTAssertEqual(error?.message, "Sign-up is closed for this app.")
    }

    func testLinkSendsProofAndSignsIn() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.path.hasSuffix("/v1/auth/oauth/ledvery/link"))
            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["challenge_id"] as? String, "chal-1")
            XCTAssertEqual(body["password"] as? String, "pw-1")
            XCTAssertEqual(body["mfa_code"] as? String, "123456")
            XCTAssertNil(body["challenge_token"])
            return TestFixtures.envelopedResponse(json: """
            {"session_token": "sess_linked", "user": \(TestFixtures.userJSON),
             "expires_at": "2026-12-21T00:00:00Z", "is_new_user": false, "is_new_link": true}
            """)
        }

        let result = await auth.linkLedveryAccount(challengeId: "chal-1", password: "pw-1", mfaCode: "123456")
        guard case .signedIn(let user)? = assertApiSuccess(result) else {
            return XCTFail("expected signedIn")
        }
        XCTAssertEqual(user.id, "usr_abc123")
        let token = await app.sessionManager.sessionToken
        XCTAssertEqual(token, "sess_linked")
    }

    func testLinkAsksForMfaCode() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 401, json: """
            {"success": false, "error": {"code": "MFA_REQUIRED", "message": "A verification code from your authenticator is required."}}
            """)
        }
        let result = await auth.linkLedveryAccount(challengeId: "chal-1", password: "pw-1")
        guard case .mfaCodeRequired(let message)? = assertApiSuccess(result) else {
            return XCTFail("expected mfaCodeRequired")
        }
        XCTAssertTrue(message.contains("verification code"))
    }

    func testLinkAsksForEmailCode() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 403, json: """
            {"success": false, "error": {"code": "LOGIN_CHALLENGE_REQUIRED",
             "message": "{\\"challenge_token\\":\\"tok-9\\",\\"method\\":\\"email\\",\\"expires_in\\":600,\\"message\\":\\"Enter the code sent to your email to finish signing in.\\"}"}}
            """)
        }
        let result = await auth.linkLedveryAccount(challengeId: "chal-1", password: "pw-1")
        guard case .emailCodeRequired(let challenge)? = assertApiSuccess(result) else {
            return XCTFail("expected emailCodeRequired")
        }
        XCTAssertEqual(challenge.challengeToken, "tok-9")
        XCTAssertEqual(challenge.expiresIn, 600)
    }

    func testLinkFailureIsNeutral() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 401, json: """
            {"success": false, "error": {"code": "LINK_FAILED", "message": "We could not verify that account."}}
            """)
        }
        let error = assertApiFailure(await auth.linkLedveryAccount(challengeId: "chal-1", password: "bad"))
        XCTAssertEqual(error?.rawCode, "LINK_FAILED")
        let token = await app.sessionManager.sessionToken
        XCTAssertNil(token)
    }
}
