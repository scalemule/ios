import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleAuth

final class AuthServiceMFASetupTests: XCTestCase {
    func testLoginCarriesSetupToken() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 403, json: """
            {"success":false,"error":{"code":"MFA_SETUP_REQUIRED","message":"MFA is required for your account. Please set up MFA to continue.","details":{"setup_token":"st_1","expires_in":600,"allowed_methods":["totp","email"],"requirement_source":"application_policy"}}}
            """)
        }
        let error = assertApiFailure(await auth.login(email: "a@b.co", password: "pw"), code: .mfaSetupRequired)
        XCTAssertEqual(error?.details?["setup_token"]?.value as? String, "st_1")
        var iterator = await app.authStateStream().makeAsyncIterator()
        let state = await iterator.next()
        guard case .mfaSetupRequired(let req) = state else { return XCTFail("got \\(String(describing: state))") }
        XCTAssertEqual(req.setupToken, "st_1")
        XCTAssertEqual(req.allowedMethods, ["totp", "email"])
        XCTAssertEqual(req.requirementSource, "application_policy")
    }

    func testOldServerWithoutTokenStillWorks() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 403, json: #"{"success":false,"error":{"code":"MFA_SETUP_REQUIRED","message":"Set up MFA"}}"#)
        }
        _ = await auth.login(email: "a@b.co", password: "pw")
        var iterator = await app.authStateStream().makeAsyncIterator()
        guard case .mfaSetupRequired(let req) = await iterator.next() else { return XCTFail("expected setup required") }
        XCTAssertNil(req.setupToken)
        XCTAssertEqual(req.allowedMethods, [])
    }

    func testTotpStartAndConfirmSignsIn() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        MockURLProtocol.requestHandler = { request in
            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["setup_token"] as? String, "st_1")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if request.url!.path == "/v1/auth/mfa/setup/totp/start" {
                return TestFixtures.envelopedResponse(json: #"{"secret":"ABC","qr_code_uri":"otpauth://totp/x","issuer":"Firehosy","account_name":"a@b.co"}"#)
            }
            XCTAssertEqual(request.url!.path, "/v1/auth/mfa/setup/totp/confirm")
            XCTAssertEqual(body["code"] as? String, "123456")
            let login = TestFixtures.loginJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            let merged = String(login.dropLast()) + #","mfa_method":"totp","backup_codes":["b1","b2"]}"#
            return TestFixtures.envelopedResponse(json: merged)
        }
        let start = assertApiSuccess(await auth.startTotpSetup(setupToken: "st_1"))
        XCTAssertEqual(start?.qrCodeUri, "otpauth://totp/x")
        let done = assertApiSuccess(await auth.confirmTotpSetup(setupToken: "st_1", code: " 123456 "))
        XCTAssertEqual(done?.backupCodes, ["b1", "b2"])
        XCTAssertEqual(done?.mfaMethod, "totp")
        let signedIn = await app.isAuthenticated
        XCTAssertTrue(signedIn)
    }

    func testExpiredTokenKeepsCode() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 410, json: #"{"success":false,"error":{"code":"MFA_SETUP_EXPIRED","message":"This setup link has expired. Sign in again."}}"#)
        }
        let error = assertApiFailure(await auth.sendEmailSetupCode(setupToken: "old"))
        XCTAssertEqual(error?.rawCode, AuthService.mfaSetupExpiredCode)
    }
}
