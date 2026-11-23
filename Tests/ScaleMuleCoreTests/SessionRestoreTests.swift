import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore

/// A stored session survives a launch without network or with the server
/// failing; only the server rejecting it (or its absolute expiry) ends it.
final class SessionRestoreTests: XCTestCase {
    private let meJSON = #"{"id":"u1","email":"sam@example.com","full_name":"Сэм 山田 🌉"}"#
    private let sam = AuthUser(id: "u1", email: "sam@example.com", fullName: "Сэм 山田 🌉")

    private func app(expires: Date = Date().addingTimeInterval(3600), absolute: Date? = nil, remember: Bool = true) async -> ScaleMuleApp {
        let (app, _) = createTestClient()
        await app.sessionManager.clear()
        await app.setCredentials(
            CredentialSet(sessionToken: "sess_1", sessionExpiresAt: expires, absoluteExpiresAt: absolute),
            user: sam
        )
        if !remember {
            // As stored by an older SDK: credentials only.
            await app.sessionManager.clear()
            try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "sess_1", sessionExpiresAt: expires, absoluteExpiresAt: absolute))
        }
        return app
    }

    private func state(_ app: ScaleMuleApp) async -> AuthState {
        await app.authState.state
    }

    override func tearDown() async throws {
        MockURLProtocol.requestHandler = nil
        let (app, _) = createTestClient()
        await app.sessionManager.clear()
    }

    func testOfflineLaunchStaysSignedInAsLastConfirmed() async {
        let app = await app()
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        await app.initialize()
        guard case .authenticated(let user) = await state(app) else { return XCTFail("signed out offline") }
        XCTAssertEqual(user.fullName, "Сэм 山田 🌉")
        let token = await app.sessionManager.sessionToken
        XCTAssertEqual(token, "sess_1")
    }

    func testServerErrorDoesNotSignOut() async {
        let app = await app()
        MockURLProtocol.requestHandler = { _ in TestFixtures.mockResponse(statusCode: 503, json: #"{"success":false,"error":{"code":"SERVICE_UNAVAILABLE","message":"down"}}"#) }
        await app.initialize()
        guard case .authenticated = await state(app) else { return XCTFail("signed out on a 503") }
    }

    func testRejectedSessionSignsOut() async {
        let app = await app()
        MockURLProtocol.requestHandler = { _ in TestFixtures.mockResponse(statusCode: 401, json: #"{"success":false,"error":{"code":"UNAUTHORIZED","message":"Session expired"}}"#) }
        await app.initialize()
        let now = await state(app)
        XCTAssertEqual(now, .unauthenticated)
        let token = await app.sessionManager.sessionToken
        XCTAssertNil(token)
        let remembered = await app.sessionManager.rememberedUser()
        XCTAssertNil(remembered, "the profile goes with the session")
    }

    func testExpiryStoredAtSignInIsNotTrustedOverTheServer() async {
        // The server slid the session forward while the app was used.
        let app = await app(expires: Date().addingTimeInterval(-3600))
        MockURLProtocol.requestHandler = { _ in TestFixtures.envelopedResponse(json: self.meJSON) }
        await app.initialize()
        let now = await state(app)
        XCTAssertEqual(now, AuthState.authenticated(self.sam))
    }

    func testAbsoluteExpiryEndsTheSessionWithoutAsking() async {
        let app = await app(absolute: Date().addingTimeInterval(-60))
        var asked = false
        MockURLProtocol.requestHandler = { _ in asked = true; return TestFixtures.envelopedResponse(json: self.meJSON) }
        await app.initialize()
        let now = await state(app)
        XCTAssertEqual(now, .unauthenticated)
        XCTAssertFalse(asked)
    }

    func testOlderInstallWithoutProfileRecoversWhenTheServerAnswers() async {
        let app = await app(remember: false)
        var online = false
        MockURLProtocol.requestHandler = { _ in
            if !online { throw URLError(.timedOut) }
            return TestFixtures.envelopedResponse(json: self.meJSON)
        }
        await app.initialize()
        let now = await state(app)
        XCTAssertEqual(now, .unauthenticated, "no profile to show yet")
        let kept = await app.sessionManager.sessionToken
        XCTAssertEqual(kept, "sess_1", "but the session is kept")
        online = true
        await app.recheckSession(token: "sess_1", delays: [0])
        let later = await state(app)
        XCTAssertEqual(later, AuthState.authenticated(self.sam))
    }

    func testOnlyDefiniteAnswersCountAsRejected() {
        XCTAssertTrue(ScaleMuleApp.isSessionRejected(ApiError(code: .unauthorized, message: "", statusCode: 401)))
        XCTAssertTrue(ScaleMuleApp.isSessionRejected(ApiError(code: .forbidden, message: "", statusCode: 403, rawCode: "SESSION_REVOKED")))
        XCTAssertFalse(ScaleMuleApp.isSessionRejected(ApiError(code: .forbidden, message: "", statusCode: 403, rawCode: "TRUST_SCORE_TOO_LOW")))
        XCTAssertFalse(ScaleMuleApp.isSessionRejected(.network("offline")))
        XCTAssertFalse(ScaleMuleApp.isSessionRejected(.timeout()))
        XCTAssertFalse(ScaleMuleApp.isSessionRejected(ApiError(code: .rateLimited, message: "", statusCode: 429)))
        XCTAssertFalse(ScaleMuleApp.isSessionRejected(ApiError(code: .internalError, message: "", statusCode: 500)))
    }
}
