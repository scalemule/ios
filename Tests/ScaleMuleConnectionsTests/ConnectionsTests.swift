import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleConnections

@MainActor
final class ConnectionsTests: XCTestCase {
    private let me = "019b0000-0000-7000-8000-0000000000aa"
    private let them = "019b0000-0000-7000-8000-0000000000bb"
    private let other = "019b0000-0000-7000-8000-0000000000cc"
    private let r1 = "019b0000-0000-7000-8000-00000000d001"
    private let r2 = "019b0000-0000-7000-8000-00000000d002"

    private var seen: [String] = []
    /// Answers by "METHOD path" (path without /v1/social-policy).
    private var answers: [String: (HTTPURLResponse, Data)] = [:]

    private func service() -> ConnectionsService {
        let (app, _) = createTestClient()
        MockURLProtocol.requestHandler = { [unowned self] request in
            let path = (request.url?.path ?? "").replacingOccurrences(of: "/v1/social-policy", with: "")
            let call = "\(request.httpMethod ?? "") \(path)"
            self.seen.append(call)
            return self.answers[call] ?? TestFixtures.envelopedResponse(json: "null")
        }
        return ConnectionsService(app: app)
    }

    private func ok(_ json: String) -> (HTTPURLResponse, Data) { TestFixtures.envelopedResponse(json: json) }

    private func refusal(_ status: Int, _ code: String, _ message: String = "No") -> (HTTPURLResponse, Data) {
        TestFixtures.mockResponse(statusCode: status, json: "{\"success\":false,\"error\":{\"code\":\"\(code)\",\"message\":\"\(message)\"}}")
    }

    private func requestJSON(_ id: String, from: String, note: String? = nil, status: String = "pending") -> String {
        let text = note.map { "\"\($0)\"" } ?? "null"
        return """
        {"id": "\(id)", "actor_identity_id": "\(from)", "target_identity_id": "\(me)", "request_type": "connect_request",
         "intro_message": \(text), "context_type": null, "context_id": null, "status": "\(status)", "created_at": "2026-11-24T10:00:00.123456789Z"}
        """
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    // MARK: - Service

    func testStateReadsWhatICanDo() async {
        let connections = service()
        answers["GET /connections/\(them)"] = ok("""
        {"state": "request_received", "request_id": "\(r1)", "can_message": false, "can_request": false, "direct_message_policy": "connections_only"}
        """)
        let state = assertApiSuccess(await connections.state(with: them))
        XCTAssertEqual(state, ConnectionState(kind: .requestReceived, requestId: r1, canMessage: false, canRequest: false))

        answers["GET /connections/\(them)"] = ok("{\"state\": \"something_new\"}")
        let unknown = assertApiSuccess(await connections.state(with: them))
        XCTAssertEqual(unknown?.kind, ConnectionState.Kind.none, "a state this SDK does not know is treated as not connected")
        XCTAssertEqual(unknown?.canMessage, false)
    }

    func testAServerWithoutConnectionsMeansMessagesAreOpen() async {
        let connections = service()
        answers["GET /connections/\(them)"] = refusal(404, "NOT_FOUND")
        let state = assertApiSuccess(await connections.state(with: them))
        XCTAssertEqual(state, .open)
        XCTAssertEqual(state?.canMessage, true)
        XCTAssertEqual(state?.canRequest, false)

        answers["GET /connections/\(them)"] = refusal(503, "SERVICE_UNAVAILABLE")
        _ = assertApiFailure(await connections.state(with: them))
    }

    func testRequestSendsATrimmedNoteAndIsNeverRetried() async {
        let (app, _) = createTestClient()
        let connections = ConnectionsService(app: app)
        var bodies: [[String: Any]] = []
        var calls = 0
        MockURLProtocol.requestHandler = { request in
            calls += 1
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/social-policy/contact-requests")
            bodies.append(self.bodyJSON(request) ?? [:])
            return TestFixtures.envelopedResponse(json: "{\"id\": \"\(self.r1)\", \"status\": \"pending\"}")
        }
        let sent = assertApiSuccess(await connections.request(userId: them, note: "  Hi, we met at Lake Merritt 🌊  "))
        XCTAssertEqual(sent?.id, r1)
        XCTAssertEqual(sent?.isConnected, false)
        XCTAssertEqual(bodies[0]["target_identity_id"] as? String, them)
        XCTAssertEqual(bodies[0]["request_type"] as? String, "connect_request")
        XCTAssertEqual(bodies[0]["intro_message"] as? String, "Hi, we met at Lake Merritt 🌊")

        _ = await connections.request(userId: them, note: "   ")
        XCTAssertNil(bodies[1]["intro_message"], "an empty note is not sent")

        let long = String(repeating: "界🌊", count: 400)
        _ = await connections.request(userId: them, note: long)
        XCTAssertEqual((bodies[2]["intro_message"] as? String)?.count, 300, "cut by characters, never inside one")

        calls = 0
        MockURLProtocol.requestHandler = { _ in
            calls += 1
            return TestFixtures.mockResponse(statusCode: 503, json: "{\"success\":false,\"error\":{\"code\":\"SERVICE_UNAVAILABLE\",\"message\":\"x\"}}")
        }
        _ = assertApiFailure(await connections.request(userId: them))
        XCTAssertEqual(calls, 1, "a request that may have gone out is not sent twice")
    }

    func testListsAnswersWithdrawAndRemoveUseTheirRoutes() async {
        let (app, _) = createTestClient()
        let connections = ConnectionsService(app: app)
        var seen: [String] = []
        MockURLProtocol.requestHandler = { request in
            let path = (request.url?.path ?? "").replacingOccurrences(of: "/v1/social-policy", with: "")
            seen.append("\(request.httpMethod ?? "") \(path)")
            if path.hasSuffix("/inbox") {
                XCTAssertEqual(self.query(request)["status"], "pending")
                XCTAssertEqual(self.query(request)["limit"], "100")
                XCTAssertEqual(self.query(request)["before"], self.r2)
                return TestFixtures.envelopedResponse(json: "[\(self.requestJSON(self.r1, from: self.them, note: "it's me & a <friend>"))]")
            }
            if path == "/connections" {
                return TestFixtures.envelopedResponse(json: "{\"connections\": [{\"user_id\": \"\(self.them)\", \"connected_at\": \"2026-11-24T10:00:00Z\"}], \"has_more\": true, \"next_before\": \"cursor-1\"}")
            }
            if path.hasSuffix("/accept") { return TestFixtures.envelopedResponse(json: "{\"id\": \"\(self.r1)\", \"status\": \"accepted\"}") }
            return TestFixtures.envelopedResponse(json: "null")
        }
        let inbox = assertApiSuccess(await connections.incoming(limit: 500, before: r2))
        XCTAssertEqual(inbox?.first?.fromUserId, them)
        XCTAssertEqual(inbox?.first?.note, "it's me & a <friend>", "the note is shown as typed")
        XCTAssertNotNil(inbox?.first?.createdDate)
        _ = await connections.sent()
        let accepted = assertApiSuccess(await connections.accept(requestId: r1))
        XCTAssertEqual(accepted?.isConnected, true)
        _ = await connections.decline(requestId: r1)
        _ = await connections.report(requestId: r1)
        _ = assertApiSuccess(await connections.withdraw(requestId: r1))
        let page = assertApiSuccess(await connections.connections())
        XCTAssertEqual(page?.connections.map(\.userId), [them])
        XCTAssertEqual(page?.hasMore, true)
        XCTAssertEqual(page?.nextBefore, "cursor-1")
        _ = assertApiSuccess(await connections.remove(userId: them))
        XCTAssertEqual(seen, [
            "GET /contact-requests/inbox", "GET /contact-requests/sent",
            "POST /contact-requests/\(r1)/accept", "POST /contact-requests/\(r1)/decline", "POST /contact-requests/\(r1)/report",
            "DELETE /contact-requests/\(r1)", "GET /connections", "DELETE /connections/\(them)",
        ])
    }

    // MARK: - Requests waiting for me

    func testRequestsModelListsCountsAndAnswers() async {
        let connections = service()
        answers["GET /contact-requests/inbox"] = ok("""
        [\(requestJSON(r1, from: them, note: "Hi")), \(requestJSON(r2, from: other)), \(requestJSON("old", from: other, status: "accepted"))]
        """)
        let model = ConnectionRequestsModel()
        await model.load()
        XCTAssertFalse(model.hasLoaded, "nothing happens before a service is attached")
        model.attach(connections)
        await model.load()
        XCTAssertEqual(model.requests.map(\.id), [r1, r2], "only requests still waiting")
        XCTAssertEqual(model.count, 2)

        answers["POST /contact-requests/\(r1)/accept"] = ok("{\"id\": \"\(r1)\", \"status\": \"accepted\"}")
        let before = model.changes
        let accepted = await model.accept(model.requests[0])
        XCTAssertTrue(accepted)
        XCTAssertEqual(model.requests.map(\.id), [r2])
        XCTAssertEqual(model.changes, before + 1, "screens showing that person ask again")

        // Declining something already withdrawn just removes it.
        answers["POST /contact-requests/\(r2)/decline"] = refusal(404, "NOT_FOUND")
        let declined = await model.decline(model.requests[0])
        XCTAssertFalse(declined)
        XCTAssertTrue(model.requests.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testRequestsModelKeepsTheListWhenAnAnswerFailsAndHidesBlockedPeople() async {
        let connections = service()
        answers["GET /contact-requests/inbox"] = ok("[\(requestJSON(r1, from: them)), \(requestJSON(r2, from: other))]")
        let model = ConnectionRequestsModel()
        model.attach(connections)
        await model.load()

        answers["POST /contact-requests/\(r1)/accept"] = refusal(503, "SERVICE_UNAVAILABLE")
        let accepted = await model.accept(model.requests[0])
        XCTAssertFalse(accepted)
        XCTAssertEqual(model.count, 2, "still there to try again")
        XCTAssertNotNil(model.errorMessage)

        model.hiddenUserIds = [other.replacingOccurrences(of: "-", with: "").uppercased()]
        XCTAssertEqual(model.requests.map(\.id), [r1], "a blocked person's request is not shown")
        await model.load()
        XCTAssertEqual(model.requests.map(\.id), [r1])

        // A later failed refresh keeps what is on screen.
        answers["GET /contact-requests/inbox"] = refusal(503, "SERVICE_UNAVAILABLE")
        model.errorMessage = nil
        await model.load()
        XCTAssertEqual(model.count, 1)
        XCTAssertNil(model.errorMessage)

        model.reset()
        XCTAssertTrue(model.requests.isEmpty)
        XCTAssertFalse(model.hasLoaded)
    }

    func testRequestsModelOnAnOlderServerIsSimplyEmpty() async {
        let connections = service()
        answers["GET /contact-requests/inbox"] = refusal(404, "NOT_FOUND")
        let model = ConnectionRequestsModel()
        model.attach(connections)
        await model.load()
        XCTAssertTrue(model.hasLoaded)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.count, 0)
    }

    // MARK: - One person

    func testConnectThenTheyAccept() async {
        let connections = service()
        answers["GET /connections/\(them)"] = ok("{\"state\": \"none\", \"request_id\": null, \"can_message\": false, \"can_request\": true}")
        let model = ConnectionModel(userId: them, service: connections)
        XCTAssertNil(model.state)
        await model.load()
        XCTAssertEqual(model.state?.kind, ConnectionState.Kind.none)
        XCTAssertEqual(model.state?.canRequest, true)

        answers["POST /contact-requests"] = ok("{\"id\": \"\(r1)\", \"status\": \"pending\"}")
        let asked = await model.connect(note: "Hi")
        XCTAssertTrue(asked)
        XCTAssertEqual(model.state, ConnectionState(kind: .requestSent, requestId: r1, canMessage: false, canRequest: false))

        answers["DELETE /contact-requests/\(r1)"] = ok("null")
        let withdrawn = await model.withdraw()
        XCTAssertTrue(withdrawn)
        XCTAssertTrue(seen.contains("DELETE /contact-requests/\(r1)"))
        XCTAssertEqual(model.state?.kind, ConnectionState.Kind.none, "asked the server again")
    }

    func testConnectWhenTheyAskedFirstConnectsAtOnce() async {
        let connections = service()
        answers["GET /contact-requests/inbox"] = ok("[\(requestJSON(r1, from: them))]")
        let requests = ConnectionRequestsModel()
        requests.attach(connections)
        await requests.load()
        let model = ConnectionModel(userId: them, service: connections, requests: requests)
        answers["POST /contact-requests"] = ok("{\"id\": \"\(r1)\", \"status\": \"accepted\"}")
        let asked = await model.connect()
        XCTAssertTrue(asked)
        XCTAssertEqual(model.state?.kind, .connected)
        XCTAssertEqual(model.state?.canMessage, true)
        XCTAssertTrue(requests.requests.isEmpty, "their request is no longer waiting")
    }

    func testAcceptDeclineAndRemoveFromAProfile() async {
        let connections = service()
        answers["GET /connections/\(them)"] = ok("{\"state\": \"request_received\", \"request_id\": \"\(r1)\", \"can_message\": false, \"can_request\": false}")
        let model = ConnectionModel(userId: them, service: connections)
        let early = await model.accept()
        XCTAssertFalse(early, "nothing to accept before the state is known")
        await model.load()

        answers["POST /contact-requests/\(r1)/accept"] = ok("{\"id\": \"\(r1)\", \"status\": \"accepted\"}")
        let accepted = await model.accept()
        XCTAssertTrue(accepted)
        XCTAssertEqual(model.state?.kind, .connected)

        answers["GET /connections/\(them)"] = ok("{\"state\": \"none\", \"can_message\": false, \"can_request\": true}")
        let removed = await model.remove()
        XCTAssertTrue(removed)
        XCTAssertTrue(seen.contains("DELETE /connections/\(them)"))
        XCTAssertEqual(model.state?.kind, ConnectionState.Kind.none)
        let again = await model.remove()
        XCTAssertFalse(again, "not connected: nothing to remove")
    }

    func testRefusalsReadLikeSomethingAPersonCanActOn() async {
        let connections = service()
        answers["GET /connections/\(them)"] = ok("{\"state\": \"none\", \"can_message\": false, \"can_request\": true}")
        let model = ConnectionModel(userId: them, service: connections)
        await model.load()

        answers["POST /contact-requests"] = refusal(429, "RATE_LIMITED")
        let limited = await model.connect()
        XCTAssertFalse(limited)
        XCTAssertEqual(model.errorMessage, "You've sent a lot of requests today. Try again tomorrow.")
        XCTAssertEqual(model.state?.kind, ConnectionState.Kind.none)

        answers["POST /contact-requests"] = refusal(403, "FORBIDDEN", "You cannot send a contact request to this person")
        let blocked = await model.connect()
        XCTAssertFalse(blocked)
        XCTAssertEqual(model.errorMessage, "You cannot send a contact request to this person")

        // Already connected (another phone accepted): not an error.
        answers["POST /contact-requests"] = refusal(409, "ALREADY_CONNECTED")
        answers["GET /connections/\(them)"] = ok("{\"state\": \"connected\", \"can_message\": true, \"can_request\": false}")
        let already = await model.connect()
        XCTAssertTrue(already)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.state?.kind, .connected)
    }

    func testAProfileAsksAgainWhenARequestIsAnsweredElsewhere() async {
        let connections = service()
        answers["GET /contact-requests/inbox"] = ok("[\(requestJSON(r1, from: them))]")
        answers["GET /connections/\(them)"] = ok("{\"state\": \"request_received\", \"request_id\": \"\(r1)\", \"can_message\": false, \"can_request\": false}")
        let requests = ConnectionRequestsModel()
        requests.attach(connections)
        await requests.load()
        let model = ConnectionModel(userId: them, service: connections, requests: requests)
        await model.load()

        answers["POST /contact-requests/\(r1)/accept"] = ok("{\"id\": \"\(r1)\", \"status\": \"accepted\"}")
        answers["GET /connections/\(them)"] = ok("{\"state\": \"connected\", \"can_message\": true, \"can_request\": false}")
        await requests.accept(requests.requests[0])
        for _ in 0..<50 where model.state?.kind != .connected {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.state?.kind, .connected, "accepted in the requests list: the profile shows Message")
    }
}
