import XCTest
@testable import ScaleMuleSafety
import ScaleMuleCore
import ScaleMuleTestHelpers

final class SupportDeskServiceTests: XCTestCase {
    private let endpoint = URL(string: "https://example.com/api/support/messages")!

    private func desk(signedIn: Bool = true) async -> SupportDeskService {
        let (app, urlSession) = createTestClient()
        if signedIn {
            try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600)))
        }
        return SupportDeskService(app: app, endpoint: endpoint, urlSession: urlSession)
    }

    private func reply(_ status: Int, _ json: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, Data(json.utf8))
    }

    func testReadsTheConversationFromTheAppsOwnSiteWithThePersonsSession() async {
        let desk = await desk()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url, self.endpoint)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sess_123")
            // The app's ScaleMule key is for ScaleMule, never for another host.
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
            return self.reply(200, """
            {"ok":true,"messages":[
              {"id":"m1","text":"Не могу войти 🐶","from":"you","sent_at":"2026-11-28T08:00:00.123Z"},
              {"id":"m2","text":"你好, try again now","from":"team","sent_at":"2026-11-28T08:02:00Z"}]}
            """)
        }
        let thread = assertApiSuccess(await desk.messages())
        XCTAssertEqual(thread?.map(\.id), ["m1", "m2"])
        XCTAssertEqual(thread?.first?.text, "Не могу войти 🐶")
        XCTAssertEqual(thread?.first?.from, .you)
        XCTAssertEqual(thread?.last?.from, .team)
        XCTAssertNotNil(thread?.first?.sentAt)
        XCTAssertNotNil(thread?.last?.sentAt)
    }

    func testAnEmptyConversationIsNotAnError() async {
        let desk = await desk()
        MockURLProtocol.requestHandler = { _ in self.reply(200, #"{"ok":true,"messages":[]}"#) }
        let thread = assertApiSuccess(await desk.messages())
        XCTAssertEqual(thread, [])
    }

    func testSendsTheMessageWithTheAppBuildAndDevice() async {
        let desk = await desk()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["content"] as? String, "My video won't upload")
            let device = body["device"] as? [String: String]
            XCTAssertEqual(device, ["version": "1.4", "build": "31", "os": "26.1", "model": "iPhone17,1"])
            return self.reply(200, #"{"ok":true,"message":{"id":"m9","text":"My video won't upload","from":"you","sent_at":"2026-11-28T08:00:00Z"}}"#)
        }
        let sent = assertApiSuccess(await desk.send("  My video won't upload \n", device: SupportDeskDevice(version: "1.4", build: "31", os: "26.1", model: "iPhone17,1")))
        XCTAssertEqual(sent?.id, "m9")
        XCTAssertEqual(sent?.from, .you)
    }

    func testARefusalKeepsTheSitesPlainSentence() async {
        let desk = await desk()
        MockURLProtocol.requestHandler = { _ in
            self.reply(422, #"{"ok":false,"code":"invalid_message","message":"Write a message of up to 4000 characters."}"#)
        }
        let error = assertApiFailure(await desk.send("x"))
        XCTAssertEqual(error?.statusCode, 422)
        XCTAssertEqual(error?.rawCode, "invalid_message")
        XCTAssertEqual(error?.userFacingMessage, "Write a message of up to 4000 characters.")
    }

    func testAnExpiredTokenIsRenewedOnceThenTheMessageIsSent() async {
        let desk = await desk()
        nonisolated(unsafe) var calls: [String] = []
        MockURLProtocol.requestHandler = { request in
            calls.append("\(request.httpMethod ?? "") \(request.url?.host ?? "")\(request.url?.path ?? "")")
            if request.url?.path == "/v1/auth/me" {
                return TestFixtures.mockResponse(json: #"{"success":true,"data":{"id":"u1","email":"a@b.co"}}"#)
            }
            let supportCalls = calls.filter { $0.contains("example.com") }.count
            return supportCalls == 1
                ? self.reply(401, #"{"ok":false,"code":"sign_in","message":"Sign in again, then send your message."}"#)
                : self.reply(200, #"{"ok":true,"message":{"id":"m1","text":"hello there","from":"you","sent_at":null}}"#)
        }
        let sent = assertApiSuccess(await desk.send("hello there"))
        XCTAssertEqual(sent?.id, "m1")
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.first, "POST example.com/api/support/messages")
        XCTAssertTrue(calls[1].hasSuffix("/v1/auth/me"))
        XCTAssertEqual(calls.last, "POST example.com/api/support/messages")
    }

    func testSignedOutNeverCallsTheSite() async {
        let desk = await desk(signedIn: false)
        MockURLProtocol.requestHandler = { _ in
            XCTFail("no request expected")
            return self.reply(500, "{}")
        }
        let error = assertApiFailure(await desk.messages())
        XCTAssertEqual(error?.code, .unauthorized)
    }

    func testASiteFailureIsNeverShownAsAnInternalError() async {
        let desk = await desk()
        MockURLProtocol.requestHandler = { _ in self.reply(503, "<html>bad gateway</html>") }
        let error = assertApiFailure(await desk.send("hello there"))
        XCTAssertEqual(error?.statusCode, 503)
        XCTAssertFalse(error?.userFacingMessage.localizedCaseInsensitiveContains("internal") ?? true)
        XCTAssertFalse(error?.userFacingMessage.isEmpty ?? true)
    }
}
