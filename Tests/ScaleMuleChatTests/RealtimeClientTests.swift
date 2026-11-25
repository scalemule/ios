import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleRealtime

@MainActor
final class RealtimeClientTests: XCTestCase {
    private func client(_ box: SocketBox) -> RealtimeClient {
        let (app, _) = createTestClient()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/realtime/ws/ticket")
            return TestFixtures.mockResponse(json: "{\"ticket\": \"t-\(box.sockets.count + 1)\", \"expires_in\": 30}")
        }
        return RealtimeClient(client: app.client, heartbeat: 3600, socketFactory: { box.make($0) }, pause: { _ in
            try? await Task.sleep(nanoseconds: 2_000_000)
        })
    }

    func testConnectsWithATicketAndSubscribes() async {
        let box = SocketBox()
        let realtime = client(box)
        let subscription = realtime.subscribe("conversation:c1")
        realtime.connect()
        await eventually("connected") { realtime.status == .connected }

        XCTAssertEqual(box.urls.first?.scheme, "wss")
        XCTAssertEqual(box.urls.first?.path, "/v1/realtime/ws")
        XCTAssertEqual(box.urls.first?.query, "ticket=t-1")
        await eventually("subscribe frame") { box.sockets[0].frames.contains(["type": "subscribe", "channel": "conversation:c1"]) }

        // A second subscription shares the channel; the last one to go leaves it.
        let second = realtime.subscribe("conversation:c1")
        subscription.cancel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(box.sockets[0].frames.contains { $0["type"] == "unsubscribe" })
        second.cancel()
        await eventually("unsubscribe frame") { box.sockets[0].frames.contains(["type": "unsubscribe", "channel": "conversation:c1"]) }
        XCTAssertEqual(box.sockets[0].frames.filter { $0["type"] == "subscribe" }.count, 1)
        realtime.disconnect()
        XCTAssertEqual(realtime.status, .disconnected)
        XCTAssertTrue(box.sockets[0].isClosed)
    }

    func testDeliversEventsAndIgnoresOtherFrames() async {
        let box = SocketBox()
        let realtime = client(box)
        var heard: [RealtimeEvent] = []
        let listener = realtime.onEvent { heard.append($0) }
        realtime.connect()
        await eventually("connected") { realtime.status == .connected }

        let socket = box.sockets[0]
        socket.push("{\"type\": \"auth_success\"}")
        socket.push("{\"type\": \"subscribed\", \"channel\": \"private:app:me\"}")
        socket.push("pong")
        socket.push("not json")
        socket.push("{\"type\": \"message\", \"channel\": \"conversation:c1\", \"data\": {\"event\": \"new_message\", \"data\": {\"id\": \"m1\", \"content\": \"привет 👋\"}}}")
        await eventually("event") { heard.count == 1 }
        XCTAssertEqual(heard[0].channel, "conversation:c1")
        XCTAssertEqual(heard[0].name, "new_message")
        XCTAssertEqual(heard[0].string("content"), "привет 👋")

        listener.cancel()
        try? await Task.sleep(nanoseconds: 20_000_000)
        socket.push("{\"type\": \"message\", \"channel\": \"conversation:c1\", \"data\": {\"event\": \"new_message\", \"data\": {\"id\": \"m2\"}}}")
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(heard.count, 1)
        realtime.disconnect()
    }

    func testReconnectsAndSubscribesAgain() async {
        let box = SocketBox()
        let realtime = client(box)
        let subscription = realtime.subscribe("conversation:c1")
        realtime.connect()
        await eventually("connected") { realtime.status == .connected && box.sockets.count == 1 }

        // The network drops.
        box.sockets[0].close()
        await eventually("second connection") { box.sockets.count == 2 && realtime.status == .connected }
        XCTAssertEqual(realtime.connectionCount, 2)
        XCTAssertEqual(box.urls[1].query, "ticket=t-2", "a ticket works once: every connection asks for a new one")
        await eventually("subscribed again") { box.sockets[1].frames.contains(["type": "subscribe", "channel": "conversation:c1"]) }

        // The server asks the phone to come back (a moved cell, an expiring token).
        box.sockets[1].push("{\"type\": \"reconnect\", \"reason\": \"relocation\", \"reresolve_placement\": true}")
        await eventually("third connection") { box.sockets.count == 3 && realtime.status == .connected }
        XCTAssertTrue(box.sockets[1].isClosed)

        realtime.disconnect()
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(box.sockets.count, 3, "no reconnect after disconnect()")
        subscription.cancel()
    }

    func testKeepsTryingWhenTheTicketIsRefused() async {
        let box = SocketBox()
        let realtime = client(box)
        var calls = 0
        MockURLProtocol.requestHandler = { _ in
            calls += 1
            if calls < 3 { return TestFixtures.mockResponse(statusCode: 503, json: "{\"success\": false, \"error\": {\"code\": \"unavailable\", \"message\": \"down\"}}") }
            return TestFixtures.mockResponse(json: "{\"ticket\": \"late\"}")
        }
        realtime.connect()
        await eventually("connected") { realtime.status == .connected }
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(box.urls.first?.query, "ticket=late")
        realtime.disconnect()
    }

    func testAConnectionTheServerNeverAnswersIsNotOpen() async {
        let box = SocketBox()
        box.greets = false
        let realtime = client(box)
        let subscription = realtime.subscribe("conversation:c1")
        realtime.connect()
        await eventually("socket made") { box.sockets.count == 1 }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(realtime.status, .connecting, "a refused handshake looks like this: a socket that says nothing")
        XCTAssertEqual(realtime.connectionCount, 0)
        XCTAssertTrue(box.sockets[0].frames.isEmpty, "nothing is sent before the server answers")

        box.sockets[0].close()
        await eventually("tries again") { box.sockets.count == 2 }
        box.sockets[1].push("{\"type\": \"auth_success\"}")
        await eventually("open") { realtime.status == .connected }
        XCTAssertEqual(realtime.connectionCount, 1)
        await eventually("subscribed") { box.sockets[1].frames.contains(["type": "subscribe", "channel": "conversation:c1"]) }
        realtime.disconnect()
        subscription.cancel()
    }

    func testDelayGrowsAndStops() {
        XCTAssertEqual(RealtimeClient.delay(attempt: 1, base: 1, max: 30, jitter: 0), 1)
        XCTAssertEqual(RealtimeClient.delay(attempt: 3, base: 1, max: 30, jitter: 0), 4)
        XCTAssertEqual(RealtimeClient.delay(attempt: 20, base: 1, max: 30, jitter: 0), 30)
        XCTAssertEqual(RealtimeClient.delay(attempt: 2, base: 1, max: 30, jitter: 0.25), 1.5)
    }

    func testSocketAddress() {
        XCTAssertEqual(RealtimeClient.socketURL(base: URL(string: "https://api.scalemule.com")!, ticket: "a b")?.absoluteString, "wss://api.scalemule.com/v1/realtime/ws?ticket=a%20b")
        XCTAssertEqual(RealtimeClient.socketURL(base: URL(string: "http://localhost:8080")!, ticket: "t")?.scheme, "ws")
    }

    func testEventShapes() {
        let wrapped = RealtimeClient.event(channel: "c", data: ["event": "user_typing", "data": ["user_id": "u1"]])
        XCTAssertEqual(wrapped?.name, "user_typing")
        XCTAssertEqual(wrapped?.string("user_id"), "u1")
        let flat = RealtimeClient.event(channel: "c", data: ["type": "new_message", "id": "m1"])
        XCTAssertEqual(flat?.name, "new_message")
        XCTAssertEqual(flat?.string("id"), "m1")
        XCTAssertNil(RealtimeClient.event(channel: "c", data: ["id": "m1"]))
        XCTAssertNil(RealtimeClient.event(channel: "c", data: "text"))
    }
}
