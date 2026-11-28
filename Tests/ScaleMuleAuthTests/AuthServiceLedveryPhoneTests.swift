import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleAuth

final class AuthServiceLedveryPhoneTests: XCTestCase {
    private func refusal(_ status: Int, _ code: String, _ message: String) -> (HTTPURLResponse, Data) {
        TestFixtures.mockResponse(statusCode: status, json: """
        {"success": false, "error": {"code": "\(code)", "message": "\(message)"}}
        """)
    }

    /// A person with a phone number and nothing else: no email, no name.
    private let phoneOnlyUser = """
    {"id": "usr_phone1", "sm_application_id": "app_123", "email": null, "phone": "+14155550134",
     "username": null, "full_name": null, "avatar_url": null, "email_verified": false,
     "phone_verified": true, "mfa_enabled": false, "status": "active"}
    """

    func testAskingForACodeSendsTheNumberAndSignsNobodyIn() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        var body: [String: Any]?
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.path.hasSuffix("/v1/auth/oauth/ledvery/phone-native/start"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "no session needed")
            body = self.bodyJSON(request)
            return TestFixtures.envelopedResponse(json: """
            {"phone": "+14155550134", "resend_after_seconds": 45, "expires_in_seconds": 600}
            """)
        }
        let sent = assertApiSuccess(await auth.sendLedveryPhoneCode(phone: " +14155550134 "))
        XCTAssertEqual(sent, LedveryPhoneCodeSent(phone: "+14155550134", resendAfterSeconds: 45, expiresInSeconds: 600))
        XCTAssertEqual(body?["phone"] as? String, "+14155550134", "trimmed")
        let token = await app.sessionManager.sessionToken
        XCTAssertNil(token)
    }

    func testAnAnswerWithoutTimesUsesTheUsualOnes() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.envelopedResponse(json: #"{"phone": "+442079460958"}"#)
        }
        let sent = assertApiSuccess(await auth.sendLedveryPhoneCode(phone: "+442079460958"))
        XCTAssertEqual(sent?.resendAfterSeconds, 30)
        XCTAssertEqual(sent?.expiresInSeconds, 600)
    }

    func testTheRightCodeSignsInAPersonWhoHasNoEmail() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        var body: [String: Any]?
        let user = phoneOnlyUser
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.path.hasSuffix("/v1/auth/oauth/ledvery/phone-native/verify"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            body = self.bodyJSON(request)
            return TestFixtures.envelopedResponse(json: """
            {"session_token": "sess_phone", "user": \(user),
             "expires_at": "2026-12-27T00:00:00Z", "is_new_user": true, "is_new_link": false}
            """)
        }
        // iOS can hand the code over with a space in the middle.
        let signIn = assertApiSuccess(await auth.signInWithLedveryPhone(phone: "+14155550134", code: " 123 456 "))
        XCTAssertEqual(signIn?.user.id, "usr_phone1")
        XCTAssertNil(signIn?.user.email)
        XCTAssertEqual(signIn?.user.phone, "+14155550134")
        XCTAssertEqual(signIn?.isNewUser, true)
        XCTAssertEqual(body?["phone"] as? String, "+14155550134")
        XCTAssertEqual(body?["code"] as? String, "123456")
        let token = await app.sessionManager.sessionToken
        XCTAssertEqual(token, "sess_phone")
    }

    func testAWrongCodeStaysSignedOutWithItsSentence() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        MockURLProtocol.requestHandler = { _ in
            self.refusal(400, "PHONE_CODE_INVALID", "That code is not right or is too old. Ask for a new one.")
        }
        let result = await auth.signInWithLedveryPhone(phone: "+14155550134", code: "000000")
        XCTAssertEqual(result.error?.rawCode, AuthService.phoneCodeInvalidCode)
        XCTAssertEqual(result.error?.message, "That code is not right or is too old. Ask for a new one.")
        let token = await app.sessionManager.sessionToken
        XCTAssertNil(token)
    }

    func testRefusalsKeepTheirCodes() async {
        let (app, _) = createTestClient()
        let auth = AuthService(app: app)
        MockURLProtocol.requestHandler = { _ in
            self.refusal(429, "PHONE_CODE_LIMIT", "Too many codes were sent to this number. Try again in an hour.")
        }
        var result = await auth.sendLedveryPhoneCode(phone: "+14155550134")
        XCTAssertEqual(result.error?.code, .rateLimited)
        XCTAssertEqual(result.error?.userFacingMessage, "Too many tries. Wait a minute and try again.")
        MockURLProtocol.requestHandler = { _ in
            self.refusal(400, "PHONE_NOT_SUPPORTED", "We cannot text this number. Use a mobile number, or sign in another way.")
        }
        result = await auth.sendLedveryPhoneCode(phone: "+14155550134")
        XCTAssertEqual(result.error?.rawCode, AuthService.phoneNotSupportedCode)
        MockURLProtocol.requestHandler = { _ in
            self.refusal(403, "NATIVE_PHONE_NOT_ENABLED", "Phone sign-in is not enabled for this application.")
        }
        result = await auth.sendLedveryPhoneCode(phone: "+14155550134")
        XCTAssertEqual(result.error?.rawCode, AuthService.nativePhoneNotEnabledCode)
    }
}

final class PhoneNumberTests: XCTestCase {
    func testANumberWithoutACountryCodeIsReadAsUnitedStates() {
        XCTAssertEqual(PhoneNumber(typed: "(415) 555-0134")?.e164, "+14155550134")
        XCTAssertEqual(PhoneNumber(typed: "415.555.0134")?.e164, "+14155550134")
        XCTAssertEqual(PhoneNumber(typed: " 1 415 555 0134 ")?.e164, "+14155550134")
        XCTAssertEqual(PhoneNumber(typed: "+1 (415) 555-0134")?.e164, "+14155550134")
    }

    func testAnInternationalNumberKeepsItsCountryCode() {
        XCTAssertEqual(PhoneNumber(typed: "+44 20 7946 0958")?.e164, "+442079460958")
        XCTAssertEqual(PhoneNumber(typed: "+359 88 123 4567")?.e164, "+359881234567")
        // Digits typed on an Arabic keyboard are the same number.
        XCTAssertEqual(PhoneNumber(typed: "+٤٤ ٢٠ ٧٩٤٦ ٠٩٥٨")?.e164, "+442079460958")
    }

    func testWhatCannotBeANumberIsRefused() {
        for typed in ["", "555-0134", "415 555 01345", "0415 555 0134", "+0 415 555 0134", "reader@example.com",
                      "call me 4155550134", "415555013x", "+1+4155550134", "📞4155550134", "Пламен", "山田4155550134",
                      "+1234567", "½4155550134", "+1234567890123456"] {
            XCTAssertNil(PhoneNumber(typed: typed), typed)
        }
    }

    func testAUnitedStatesNumberIsShownTheWayPeopleWriteIt() {
        XCTAssertEqual(PhoneNumber.display("+14155550134"), "+1 (415) 555-0134")
        XCTAssertEqual(PhoneNumber.display("+442079460958"), "+442079460958")
        XCTAssertEqual(PhoneNumber.display("not a number"), "not a number")
    }
}
