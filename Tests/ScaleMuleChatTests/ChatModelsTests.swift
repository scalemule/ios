import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleRealtime
@testable import ScaleMuleChat

@MainActor
final class ChatModelsTests: XCTestCase {
    private let me = "019b0000-0000-7000-8000-0000000000aa"
    private let them = "019b0000-0000-7000-8000-0000000000bb"
    private let other = "019b0000-0000-7000-8000-0000000000cc"
    private let c1 = "019b0000-0000-7000-8000-00000000c001"
    private let c2 = "019b0000-0000-7000-8000-00000000c002"

    private var seen: [String] = []
    private var sendAnswer: (HTTPURLResponse, Data)?
    private var openAnswer: (HTTPURLResponse, Data)?
    /// When set, the send call waits here, so a test can look at the message while it is being sent.
    private var sendGate: DispatchSemaphore?
    private var listJSON = "[]"
    private var pageJSON = "{\"messages\": []}"

    private func chat() -> ChatService {
        let (app, _) = createTestClient()
        MockURLProtocol.requestHandler = { [unowned self] request in
            let path = request.url?.path ?? ""
            let call = "\(request.httpMethod ?? "") \(path.replacingOccurrences(of: "/v1/chat", with: ""))"
            self.seen.append(request.url?.query.map { "\(call)?\($0)" } ?? call)
            switch (request.httpMethod, path) {
            case ("POST", "/v1/chat/conversations"):
                if let answer = self.openAnswer { return answer }
                return TestFixtures.envelopedResponse(json: "{\"id\": \"\(self.c1)\", \"conversation_type\": \"direct\", \"participant_count\": 2, \"created_at\": \"2026-11-24T09:00:00Z\"}")
            case ("GET", "/v1/chat/conversations"):
                return TestFixtures.envelopedResponse(json: self.listJSON)
            case ("GET", "/v1/chat/conversations/\(self.c1)/messages"):
                return TestFixtures.envelopedResponse(json: self.pageJSON)
            case ("POST", "/v1/chat/conversations/\(self.c1)/messages"):
                self.sendGate?.wait()
                if let answer = self.sendAnswer { return answer }
                let text = (self.bodyJSON(request)?["content"] as? String) ?? ""
                return TestFixtures.envelopedResponse(json: self.messageJSON(id: "sent-\(self.seen.count)", from: self.me, text, at: "2026-11-24T10:10:00Z"))
            case ("GET", "/v1/chat/conversations/\(self.c1)/read-status"):
                return TestFixtures.envelopedResponse(json: "{\"statuses\": [{\"user_id\": \"\(self.them)\", \"last_read_at\": \"2026-11-24T10:00:30Z\"}]}")
            default:
                return TestFixtures.envelopedResponse(json: "null")
            }
        }
        return ChatService(app: app)
    }

    private func row(_ id: String, with user: String, unread: Int = 0, at time: String? = "2026-11-24T10:00:00Z", preview: String = "hi") -> String {
        let last = time.map { "\"\($0)\"" } ?? "null"
        return """
        {"id": "\(id)", "conversation_type": "direct", "participant_count": 2, "last_message_at": \(last), "unread_count": \(unread),
         "last_message_preview": "\(preview)", "last_message_sender_id": "\(user)", "counterparty_user_id": "\(user)", "is_muted": false,
         "created_at": "2026-11-24T09:00:00Z"}
        """
    }

    private func thread(_ chat: ChatService, inbox: ChatInboxModel? = nil) -> ChatThreadModel {
        ChatThreadModel(peerUserId: them, myUserId: me, chat: chat, realtime: nil, inbox: inbox, now: { Date(timeIntervalSince1970: 1_795_000_000) })
    }

    // MARK: - The list

    func testInboxLeavesOutEmptyAndBlockedConversationsAndCountsUnread() async {
        listJSON = "[\(row(c1, with: them, unread: 2)), \(row(c2, with: other, unread: 4)), \(row("c3", with: "u3", unread: 0, at: nil))]"
        let inbox = ChatInboxModel()
        inbox.attach(chat: chat(), realtime: nil, myUserId: me)
        await inbox.load()
        XCTAssertEqual(inbox.conversations.map(\.id), [c1, c2], "a conversation nobody wrote in is not shown")
        XCTAssertEqual(inbox.unread, 6)
        XCTAssertTrue(inbox.hasLoaded)

        inbox.blockedUserIds = [other.uppercased()]
        XCTAssertEqual(inbox.conversations.map(\.id), [c1])
        XCTAssertEqual(inbox.unread, 2)
        XCTAssertEqual(inbox.conversation(with: them)?.id, c1)

        inbox.noteRead(conversationId: c1)
        XCTAssertEqual(inbox.unread, 0)

        inbox.reset()
        XCTAssertTrue(inbox.conversations.isEmpty)
        XCTAssertFalse(inbox.hasLoaded)
    }

    func testInboxMovesAConversationUpWhenAMessageArrives() async {
        listJSON = "[\(row(c1, with: them)), \(row(c2, with: other))]"
        let inbox = ChatInboxModel()
        inbox.attach(chat: chat(), realtime: nil, myUserId: me)
        await inbox.load()

        let incoming: [String: Any] = ["id": "m5", "conversation_id": c2, "sender_id": other, "content": "you there?", "message_type": "text", "created_at": "2026-11-24T10:20:00Z"]
        inbox.handle(liveEvent(channel: "private:app:me", name: "new_message", incoming))
        XCTAssertEqual(inbox.conversations.map(\.id), [c2, c1])
        XCTAssertEqual(inbox.conversations[0].lastMessagePreview, "you there?")
        XCTAssertEqual(inbox.unread, 1)

        // The conversation on screen does not count as unread.
        inbox.openConversationId = c1
        inbox.handle(liveEvent(channel: "private:app:me", name: "new_message", ["id": "m6", "conversation_id": c1, "sender_id": them, "content": "ok", "created_at": "2026-11-24T10:21:00Z"]))
        XCTAssertEqual(inbox.conversations.map(\.id), [c1, c2])
        XCTAssertEqual(inbox.unread, 1)

        // Events on other channels are not the list's business.
        inbox.handle(liveEvent(channel: "conversation:\(c2)", name: "new_message", incoming))
        XCTAssertEqual(inbox.unread, 1)

        // A conversation this phone has not seen: fetch the list again.
        seen = []
        listJSON = "[\(row("c9", with: "u9", unread: 1)), \(row(c1, with: them)), \(row(c2, with: other, unread: 1))]"
        inbox.handle(liveEvent(channel: "private:app:me", name: "new_message", ["id": "m7", "conversation_id": "c9", "sender_id": "u9", "content": "hello"]))
        await eventually("reload") { inbox.conversations.count == 3 }
        XCTAssertEqual(inbox.unread, 2)
    }

    // MARK: - One conversation

    func testThreadLoadsOldestFirstAndMarksRead() async {
        pageJSON = "{\"messages\": [\(messageJSON(id: "m2", from: them, "second", at: "2026-11-24T10:00:10Z")), \(messageJSON(id: "m1", from: me, "first", at: "2026-11-24T10:00:00Z"))], \"has_more\": true}"
        listJSON = "[\(row(c1, with: them, unread: 1))]"
        let service = chat()
        let inbox = ChatInboxModel()
        inbox.attach(chat: service, realtime: nil, myUserId: me)
        await inbox.load()
        seen = []

        let model = thread(service, inbox: inbox)
        await model.start()
        XCTAssertEqual(model.messages.map(\.id), ["m1", "m2"])
        XCTAssertTrue(model.hasOlder)
        XCTAssertEqual(model.seenMessageId, "m1", "they read after my message was sent")
        XCTAssertEqual(inbox.unread, 0)
        XCTAssertEqual(inbox.openConversationId, c1)
        XCTAssertFalse(seen.contains("POST /conversations"), "the list already knows the conversation")
        XCTAssertTrue(seen.contains("POST /conversations/\(c1)/read"))

        pageJSON = "{\"messages\": [\(messageJSON(id: "m0", from: them, "older", at: "2026-11-24T09:00:00Z"))], \"has_more\": false}"
        await model.loadOlder()
        XCTAssertEqual(model.messages.map(\.id), ["m0", "m1", "m2"])
        XCTAssertTrue(seen.contains { $0.hasPrefix("GET /conversations/\(c1)/messages?") && $0.contains("before=m1") })
        XCTAssertFalse(model.hasOlder)

        model.stop()
        XCTAssertNil(inbox.openConversationId)
    }

    func testSendShowsTheMessageAtOnceThenTheServersCopy() async {
        let service = chat()
        let inbox = ChatInboxModel()
        inbox.attach(chat: service, realtime: nil, myUserId: me)
        let model = thread(service, inbox: inbox)
        await model.start()
        XCTAssertTrue(seen.contains("POST /conversations"), "the conversation is made the first time")
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertFalse(seen.contains("POST /conversations/\(c1)/read"), "nothing to mark read in an empty conversation")
        listJSON = "[\(row(c1, with: me, unread: 1))]"

        let gate = DispatchSemaphore(value: 0)
        sendGate = gate
        let sending = Task { await model.send("  hello there  ") }
        await eventually("shown at once") { model.messages.first?.delivery == .sending }
        XCTAssertEqual(model.messages.first?.content, "hello there")
        gate.signal()
        sendGate = nil
        let sent = await sending.value
        XCTAssertTrue(sent)
        XCTAssertEqual(model.messages.count, 1)
        XCTAssertEqual(model.messages[0].delivery, .sent)
        XCTAssertTrue(model.messages[0].id.hasPrefix("sent-"))
        XCTAssertEqual(inbox.conversations.first?.lastMessagePreview, "hello there", "my own message shows in the list")
        XCTAssertTrue(seen.contains("POST /conversations/\(c1)/read"), "Chat counts my own message as unread until the conversation is marked read")
        // The list as Chat gives it before that mark lands: my own message "unread".
        await inbox.load()
        XCTAssertEqual(inbox.conversations.first?.unreadCount, 0)
        XCTAssertEqual(inbox.unread, 0, "what I wrote last is never unread for me")

        let empty = await model.send("   \n ")
        XCTAssertFalse(empty)
        model.maxLength = 5
        let long = await model.send("123456")
        XCTAssertFalse(long)
        XCTAssertEqual(model.messages.count, 1)
        XCTAssertNotNil(model.errorMessage)
    }

    func testAFailedSendCanBeTriedAgainOrDropped() async {
        let service = chat()
        let model = thread(service)
        await model.start()
        sendAnswer = TestFixtures.mockResponse(statusCode: 503, json: "{\"success\": false, \"error\": {\"code\": \"unavailable\", \"message\": \"down\"}}")
        let first = await model.send("one")
        XCTAssertFalse(first)
        XCTAssertEqual(model.messages.map(\.delivery), [.failed])
        XCTAssertNotNil(model.errorMessage)

        sendAnswer = nil
        let again = await model.retry(model.messages[0])
        XCTAssertTrue(again)
        XCTAssertEqual(model.messages.map(\.delivery), [.sent])

        sendAnswer = TestFixtures.mockResponse(statusCode: 403, json: "{\"success\": false, \"error\": {\"code\": \"forbidden\", \"message\": \"Cannot send message to this user\"}}")
        let refused = await model.send("two")
        XCTAssertFalse(refused)
        XCTAssertTrue(model.cannotMessage)
        XCTAssertEqual(model.errorMessage, "You can't send messages to this person.")
        model.discard(model.messages[1])
        XCTAssertEqual(model.messages.count, 1)
    }

    func testLiveMessagesTypingReadAndDelete() async {
        pageJSON = "{\"messages\": [\(messageJSON(id: "m1", from: me, "first", at: "2026-11-24T10:00:40Z"))]}"
        let service = chat()
        let model = thread(service)
        await model.start()
        XCTAssertNil(model.seenMessageId, "they last read before my message")
        let channel = "conversation:\(c1)"
        seen = []

        model.handle(liveEvent(channel: channel, name: "user_typing", ["user_id": them]))
        XCTAssertTrue(model.otherIsTyping)
        model.handle(liveEvent(channel: channel, name: "user_typing", ["user_id": me]))

        let incoming: [String: Any] = ["id": "m2", "sender_id": them, "content": "it's me &amp; you", "message_type": "text", "created_at": "2026-11-24T10:01:00Z"]
        model.handle(liveEvent(channel: channel, name: "new_message", incoming))
        // The same message also comes on my own channel.
        model.handle(liveEvent(channel: "private:app:me", name: "new_message", incoming.merging(["conversation_id": c1]) { $1 }))
        XCTAssertEqual(model.messages.map(\.id), ["m1", "m2"])
        XCTAssertEqual(model.messages[1].content, "it's me &amp; you", "text is shown as typed")
        XCTAssertFalse(model.otherIsTyping, "a message ends typing")
        await eventually("marked read") { self.seen.contains("POST /conversations/\(self.c1)/read") }

        // Another conversation's message is not this screen's.
        model.handle(liveEvent(channel: "private:app:me", name: "new_message", ["id": "m9", "conversation_id": c2, "sender_id": other, "content": "x"]))
        model.handle(liveEvent(channel: "conversation:\(c2)", name: "new_message", ["id": "m9", "sender_id": other, "content": "x"]))
        XCTAssertEqual(model.messages.count, 2)

        model.handle(liveEvent(channel: channel, name: "messages_read", ["user_id": them, "last_read_at": "2026-11-24T10:02:00Z"]))
        XCTAssertEqual(model.seenMessageId, "m1")

        model.handle(liveEvent(channel: channel, name: "message_edited", ["message_id": "m2", "new_content": "it is me"]))
        XCTAssertEqual(model.messages[1].content, "it is me")
        XCTAssertTrue(model.messages[1].isEdited)

        model.handle(liveEvent(channel: channel, name: "message_deleted", ["message_id": "m2"]))
        XCTAssertEqual(model.messages.map(\.id), ["m1"])

        let deleted = await model.delete(model.messages[0])
        XCTAssertTrue(deleted)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertTrue(seen.contains("DELETE /messages/m1"))
    }

    func testMyOwnMessageAnnouncedBeforeTheSendAnswers() async {
        let service = chat()
        let model = thread(service)
        await model.start()
        // Hold the send call until the live event has arrived.
        let gate = DispatchSemaphore(value: 0)
        sendGate = gate
        sendAnswer = TestFixtures.envelopedResponse(json: messageJSON(id: "sent-early", from: me, "race", at: "2026-11-24T10:10:00Z"))
        let sending = Task { await model.send("race") }
        await eventually("shown") { model.messages.first?.delivery == .sending }
        model.handle(liveEvent(channel: "conversation:\(c1)", name: "new_message", ["id": "sent-early", "sender_id": me, "content": "race", "created_at": "2026-11-24T10:10:00Z"]))
        XCTAssertEqual(model.messages.map(\.id), ["sent-early"])
        gate.signal()
        sendGate = nil
        _ = await sending.value
        XCTAssertEqual(model.messages.count, 1, "one message, not two")
        XCTAssertEqual(model.messages[0].delivery, .sent)
    }

    func testTypingIsToldSparingly() async {
        pageJSON = "{\"messages\": [\(messageJSON(id: "m1", from: them, "hi"))]}"
        let service = chat()
        var clock = Date(timeIntervalSince1970: 1_795_000_000)
        let model = ChatThreadModel(peerUserId: them, myUserId: me, chat: service, realtime: nil, now: { clock })
        await model.start()
        seen = []
        model.typingChanged(hasText: true)
        model.typingChanged(hasText: true)
        clock.addTimeInterval(4)
        model.typingChanged(hasText: true)
        model.typingChanged(hasText: false)
        model.typingChanged(hasText: false)
        await eventually("three calls") { self.seen.filter { $0.hasSuffix("/typing") }.count == 3 }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(seen.filter { $0.hasSuffix("/typing") }.count, 3, "two 'typing' four seconds apart and one 'stopped'")
    }

    func testCatchUpFetchesWhatArrivedWhileOffline() async {
        pageJSON = "{\"messages\": [\(messageJSON(id: "m1", from: them, "hi"))]}"
        let service = chat()
        let model = thread(service)
        await model.start()
        seen = []
        pageJSON = "{\"messages\": [\(messageJSON(id: "m2", from: them, "still there?")), \(messageJSON(id: "m3", from: them, "hello?"))], \"has_more\": false}"
        await model.catchUp()
        XCTAssertEqual(model.messages.map(\.id), ["m1", "m2", "m3"])
        XCTAssertTrue(seen.contains { $0.contains("after=m1") })
    }

    func testDeletedMessagesAreLeftOutAndPagingGoesPastThem() async {
        func deleted(_ id: String) -> String {
            messageJSON(id: id, from: them, "Message deleted").replacingOccurrences(of: "\"is_deleted\": false", with: "\"is_deleted\": true")
        }
        pageJSON = "{\"messages\": [\(messageJSON(id: "m4", from: them, "kept")), \(deleted("m3"))], \"has_more\": true}"
        let service = chat()
        let model = thread(service)
        await model.start()
        XCTAssertEqual(model.messages.map(\.id), ["m4"], "Chat lists a deleted message as a placeholder; the screen leaves it out")

        // A whole page of deleted messages still moves the cursor on.
        pageJSON = "{\"messages\": [\(deleted("m2"))], \"has_more\": true}"
        seen = []
        await model.loadOlder()
        XCTAssertTrue(seen.contains { $0.contains("before=m3") }, "paging starts from the oldest message given, deleted or not")
        XCTAssertEqual(model.messages.map(\.id), ["m4"])
        pageJSON = "{\"messages\": [\(messageJSON(id: "m1", from: me, "first"))], \"has_more\": false}"
        seen = []
        await model.loadOlder()
        XCTAssertTrue(seen.contains { $0.contains("before=m2") })
        XCTAssertEqual(model.messages.map(\.id), ["m1", "m4"])
        XCTAssertFalse(model.hasOlder)

        // Away for a while: one message came and was deleted again, one stayed.
        pageJSON = "{\"messages\": [\(deleted("m5")), \(messageJSON(id: "m6", from: them, "still here"))], \"has_more\": false}"
        seen = []
        await model.catchUp()
        XCTAssertTrue(seen.contains { $0.contains("after=m4") })
        XCTAssertEqual(model.messages.map(\.id), ["m1", "m4", "m6"])
    }

    func testAnAppThatNeedsAConnectionSaysSoInsteadOfAnError() async {
        let refusal = #"{"success":false,"error":{"code":"CONNECTION_REQUIRED","message":"Connect with this person before sending a message"}}"#
        openAnswer = TestFixtures.mockResponse(statusCode: 403, json: refusal)
        let service = chat()
        let model = thread(service)
        await model.start()
        XCTAssertTrue(model.needsConnection, "Chat refused because the two are not connected")
        XCTAssertNil(model.errorMessage, "the screen offers Connect; it is not an error")
        XCTAssertFalse(model.cannotMessage)
        XCTAssertFalse(model.hasLoaded)

        // They accepted: the conversation opens.
        openAnswer = nil
        pageJSON = "{\"messages\": []}"
        await model.connectionChanged()
        XCTAssertFalse(model.needsConnection)
        XCTAssertTrue(model.hasLoaded)
        let sent = await model.send("hello")
        XCTAssertTrue(sent)

        // The connection ended later: what was said stays, a new send is refused.
        sendAnswer = TestFixtures.mockResponse(statusCode: 403, json: refusal)
        let second = await model.send("still there?")
        XCTAssertFalse(second)
        XCTAssertTrue(model.needsConnection)
        XCTAssertFalse(model.cannotMessage, "not connected is different from blocked")
        XCTAssertEqual(model.messages.map(\.delivery), [.sent, .failed])

        // Blocked stays what it was.
        sendAnswer = TestFixtures.mockResponse(statusCode: 403, json: #"{"success":false,"error":{"code":"FORBIDDEN","message":"Cannot send message to this user"}}"#)
        await model.connectionChanged()
        let third = await model.send("hello?")
        XCTAssertFalse(third)
        XCTAssertTrue(model.cannotMessage)
        XCTAssertFalse(model.needsConnection)
    }
}
