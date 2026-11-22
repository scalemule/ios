import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleSafety

final class SafetyServiceTests: XCTestCase {
    private func signedIn() async -> ScaleMuleApp {
        let (app, _) = createTestClient()
        try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600)))
        return app
    }

    func testPurposeIdIsStandardUUIDv5() {
        // Same as Python uuid.uuid5(uuid.NAMESPACE_URL, "scalemule-consent:firehosy_terms").
        XCTAssertEqual(ConsentService.purposeId(for: "firehosy_terms"), "d87f3d4e-f298-594f-9127-e222ec61cb27")
        XCTAssertEqual(ConsentService.purposeId(for: "a"), ConsentService.purposeId(for: "a"))
        XCTAssertNotEqual(ConsentService.purposeId(for: "a"), ConsentService.purposeId(for: "b"))
    }

    func testRecordConsentSendsVersionedCode() async {
        let consent = ConsentService(app: await signedIn())
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/compliance/consent/v2")
            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["sm_user_id"] as? String, "u1")
            XCTAssertEqual(body["purpose_code"] as? String, "firehosy_terms@2026-11-21")
            XCTAssertEqual(body["purpose_id"] as? String, "d87f3d4e-f298-594f-9127-e222ec61cb27")
            XCTAssertEqual(body["consent_given"] as? Bool, true)
            XCTAssertEqual(body["consent_method"] as? String, "explicit")
            XCTAssertEqual(body["consent_text_version"] as? String, "2026-11-21")
            return TestFixtures.mockResponse(statusCode: 201, json: """
            {"id":"c1","sm_user_id":"u1","purpose_id":"d87f3d4e-f298-594f-9127-e222ec61cb27","purpose_code":"firehosy_terms@2026-11-21","consent_given":true,"consent_method":"explicit","collection_point":"app","granted_at":"2026-11-21T00:00:00Z","withdrawn_at":null,"created_at":"2026-11-21T00:00:00Z"}
            """)
        }
        let record = assertApiSuccess(await consent.record(userId: "u1", code: "firehosy_terms", version: "2026-11-21", collectionPoint: "app"))
        XCTAssertEqual(record?.purposeCode, "firehosy_terms@2026-11-21")
    }

    func testListAndAcceptedUseNewestRecord() async {
        let consent = ConsentService(app: await signedIn())
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/compliance/consent/v2/u1")
            return TestFixtures.mockResponse(json: """
            {"success":true,"total":3,"consents":[
             {"id":"3","sm_user_id":"u1","purpose_id":"p","purpose_code":"terms@2","consent_given":true,"collection_point":"app","granted_at":null,"withdrawn_at":null,"created_at":"2026-11-21T03:00:00Z"},
             {"id":"2","sm_user_id":"u1","purpose_id":"p","purpose_code":"licence@1","consent_given":true,"collection_point":"app","granted_at":null,"withdrawn_at":"2026-11-21T02:30:00Z","created_at":"2026-11-21T02:00:00Z"},
             {"id":"1","sm_user_id":"u1","purpose_id":"p","purpose_code":"terms@1","consent_given":true,"collection_point":"app","granted_at":null,"withdrawn_at":null,"created_at":"2026-11-21T01:00:00Z"}]}
            """)
        }
        let records = assertApiSuccess(await consent.list(userId: "u1")) ?? []
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(ConsentService.accepted(in: records), ["terms@2", "terms@1"])
    }

    func testReportSendsReporterAndCategory() async {
        let reports = ReportService(app: await signedIn())
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/flagcontent/flags")
            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["content_type"] as? String, "post")
            XCTAssertEqual(body["content_id"] as? String, "post1")
            XCTAssertEqual(body["category"] as? String, "child_safety")
            XCTAssertEqual(body["reporter_id"] as? String, "u1")
            XCTAssertEqual(body["description"] as? String, "near a school")
            return TestFixtures.envelopedResponse(json: """
            {"id":"f1","content_type":"post","content_id":"post1","category":"child_safety","status":"pending","priority":"urgent","created_at":"2026-11-21T00:00:00Z"}
            """)
        }
        let report = assertApiSuccess(await reports.report(.post, id: "post1", category: .childSafety, reporterId: "u1", description: "near a school"))
        XCTAssertEqual(report?.priority, "urgent")
    }

    func testBlockAndUnblockReturn204() async {
        let blocks = BlockService(app: await signedIn())
        var paths: [String] = []
        MockURLProtocol.requestHandler = { request in
            paths.append(request.url!.path)
            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["blocker_identity_id"] as? String, "me")
            XCTAssertEqual(body["blocked_identity_id"] as? String, "them")
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        let blocked = await blocks.block("them", by: "me")
        XCTAssertTrue(blocked.isSuccess)
        let unblocked = await blocks.unblock("them", by: "me")
        XCTAssertTrue(unblocked.isSuccess)
        XCTAssertEqual(paths, ["/v1/social-policy/block", "/v1/social-policy/unblock"])
    }

    func testSupportMessageAndDisabledInbox() async {
        let support = SupportService(app: await signedIn())
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/feedback/submit")
            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["type"] as? String, "other")
            XCTAssertEqual(body["title"] as? String, "Help")
            XCTAssertEqual(body["email"] as? String, "a@b.co")
            return TestFixtures.mockResponse(statusCode: 201, json: """
            {"success":true,"data":{"id":"s1","type":"other","title":"Help","status":"new","created_at":"2026-11-21T00:00:00Z"}}
            """)
        }
        let sent = assertApiSuccess(await support.send(title: "Help", message: "Can't sign in", email: "a@b.co"))
        XCTAssertEqual(sent?.status, "new")

        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 404, json: #"{"success":false,"error":{"code":"FEEDBACK_DISABLED","message":"Feedback is not enabled"}}"#)
        }
        let error = assertApiFailure(await support.send(title: "Help", message: "x"))
        XCTAssertEqual(error?.rawCode, "FEEDBACK_DISABLED")
    }

    func testListBlocks() async {
        let blocks = BlockService(app: await signedIn())
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/social-policy/blocks")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            XCTAssertEqual(items.first { $0.name == "per_page" }?.value, "100")
            return TestFixtures.envelopedResponse(json: """
            {"blocks":[{"blocked_identity_id":"them","scope":"global_app","created_at":"2026-11-22T04:00:00Z"}],"page":1,"per_page":100,"has_more":false}
            """)
        }
        let list = assertApiSuccess(await blocks.list(perPage: 500))
        XCTAssertEqual(list?.blocks.map(\.id), ["them"])
        XCTAssertEqual(list?.hasMore, false)
    }
}
