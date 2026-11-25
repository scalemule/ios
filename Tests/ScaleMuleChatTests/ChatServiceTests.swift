import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleChat

final class ChatServiceTests: XCTestCase {
    private let me = "019b0000-0000-7000-8000-0000000000aa"
    private let them = "019b0000-0000-7000-8000-0000000000bb"
    private let conversationId = "019b0000-0000-7000-8000-00000000c001"

    private func service() -> ChatService {
        let (app, _) = createTestClient()
        return ChatService(app: app)
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testDirectConversationIsMadeWithTheOtherPerson() async {
        let chat = service()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/chat/conversations")
            let body = self.bodyJSON(request)
            XCTAssertEqual(body?["conversation_type"] as? String, "direct")
            XCTAssertEqual(body?["participant_ids"] as? [String], [self.them])
            return TestFixtures.envelopedResponse(json: """
            {"id": "\(self.conversationId)", "conversation_type": "direct", "name": null, "participant_count": 2,
             "created_at": "2026-11-24T10:00:00Z", "audience_scope": "internal"}
            """)
        }
        let made = assertApiSuccess(await chat.directConversation(with: them))
        XCTAssertEqual(made?.id, conversationId)
        XCTAssertEqual(made?.counterpartyUserId, them, "the answer does not name the other person; the SDK keeps who was asked for")
        XCTAssertTrue(made?.isDirect == true)
        XCTAssertNil(made?.lastMessageAt)
    }

    func testConversationListReadsPreviewsAndUnreadCounts() async {
        let chat = service()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/chat/conversations")
            XCTAssertEqual(self.query(request), ["page": "1", "per_page": "100", "conversation_type": "direct"])
            return TestFixtures.envelopedResponse(json: """
            [{"id": "\(self.conversationId)", "conversation_type": "direct", "name": null, "participant_count": 2,
              "last_message_at": "2026-11-24T10:05:00.250Z", "unread_count": 3, "last_message_preview": "it's on &amp; on 🎉",
              "last_message_sender_id": "\(self.them)", "last_message_type": "text", "counterparty_user_id": "\(self.them)",
              "is_muted": false, "created_at": "2026-11-24T10:00:00Z"}]
            """)
        }
        let list = assertApiSuccess(await chat.conversations(perPage: 400, type: "direct"))
        XCTAssertEqual(list?.first?.lastMessagePreview, "it's on &amp; on 🎉", "Chat stores text as typed: nothing is unescaped")
        XCTAssertEqual(list?.first?.unreadCount, 3)
        XCTAssertEqual(list?.first?.counterpartyUserId, them)
        XCTAssertNotNil(list?.first?.lastMessageDate)
    }

    func testMessagesPageAndCursors() async {
        let chat = service()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/chat/conversations/\(self.conversationId)/messages")
            XCTAssertEqual(self.query(request), ["limit": "100", "before": "m9"])
            return TestFixtures.envelopedResponse(json: """
            {"messages": [
              \(self.messageJSON(id: "m2", from: self.them, "5 < 6 & literally &lt;b&gt;")),
              {"id": "m1", "content": "<p>Hello <b>you</b></p>", "content_format": "html", "plain_text": "Hello you", "message_type": "text",
               "sender_id": "\(self.me)", "is_deleted": false, "is_edited": true, "created_at": "2026-11-24T09:59:00Z",
               "attachments": [{"file_id": "f1", "file_name": "a.jpg", "file_size": 10, "mime_type": "image/jpeg", "presigned_url": "https://x/a.jpg"}],
               "reactions": [{"emoji": "👍", "count": 1, "user_ids": ["\(self.them)"]}]}
            ], "has_more": true, "oldest_id": "m1", "newest_id": "m2"}
            """)
        }
        let page = assertApiSuccess(await chat.messages(conversationId: conversationId, limit: 500, before: "m9"))
        XCTAssertEqual(page?.messages.map(\.id), ["m2", "m1"])
        XCTAssertEqual(page?.messages[0].content, "5 < 6 & literally &lt;b&gt;", "what was typed is what is shown")
        XCTAssertEqual(page?.messages[1].content, "Hello you", "a formatted message shows as its plain text")
        XCTAssertEqual(page?.messages[1].attachments.first?.isImage, true)
        XCTAssertEqual(page?.messages[1].reactions.first?.emoji, "👍")
        XCTAssertEqual(page?.messages[1].isEdited, true)
        XCTAssertEqual(page?.hasMore, true)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(self.query(request), ["limit": "50", "after": "m2"])
            return TestFixtures.envelopedResponse(json: "{\"messages\": []}")
        }
        let newer = assertApiSuccess(await chat.messages(conversationId: conversationId, after: "m2"))
        XCTAssertEqual(newer?.messages.count, 0)
        XCTAssertEqual(newer?.hasMore, false)
    }

    func testSendIsPlainTextAndSentOnce() async {
        let chat = service()
        var calls = 0
        MockURLProtocol.requestHandler = { request in
            calls += 1
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/chat/conversations/\(self.conversationId)/messages")
            let body = self.bodyJSON(request)
            XCTAssertEqual(body?["content"] as? String, "Здравей 👋")
            XCTAssertEqual(body?["content_format"] as? String, "plain")
            XCTAssertEqual(body?["message_type"] as? String, "text")
            return TestFixtures.mockResponse(statusCode: 503, json: "{\"success\": false, \"error\": {\"code\": \"unavailable\", \"message\": \"down\"}}")
        }
        _ = assertApiFailure(await chat.send(conversationId: conversationId, text: "Здравей 👋"))
        XCTAssertEqual(calls, 1, "a message is never sent twice by itself")
    }

    func testTheOtherRoutes() async {
        let chat = service()
        var seen: [String] = []
        var bodies: [[String: Any]] = []
        MockURLProtocol.requestHandler = { request in
            seen.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            if let body = self.bodyJSON(request) { bodies.append(body) }
            return TestFixtures.envelopedResponse(json: "null")
        }
        _ = assertApiSuccess(await chat.markRead(conversationId: conversationId))
        _ = assertApiSuccess(await chat.setTyping(conversationId: conversationId, isTyping: true))
        _ = assertApiSuccess(await chat.deleteMessage(id: "m1"))
        _ = assertApiSuccess(await chat.react(messageId: "m1", emoji: "👍"))
        _ = assertApiSuccess(await chat.report(messageId: "m1", reason: .harassment, description: "rude"))
        _ = assertApiSuccess(await chat.mute(conversationId: conversationId))
        _ = assertApiSuccess(await chat.unmute(conversationId: conversationId))
        _ = assertApiSuccess(await chat.block(userId: them))
        _ = assertApiSuccess(await chat.unblock(userId: them))
        XCTAssertEqual(seen, [
            "POST /v1/chat/conversations/\(conversationId)/read",
            "POST /v1/chat/conversations/\(conversationId)/typing",
            "DELETE /v1/chat/messages/m1",
            "POST /v1/chat/messages/m1/reactions",
            "POST /v1/chat/messages/m1/report",
            "POST /v1/chat/conversations/\(conversationId)/mute",
            "DELETE /v1/chat/conversations/\(conversationId)/mute",
            "POST /v1/chat/users/\(them)/block",
            "DELETE /v1/chat/users/\(them)/block",
        ])
        XCTAssertEqual(bodies.first { $0["is_typing"] != nil }?["is_typing"] as? Bool, true)
        XCTAssertEqual(bodies.first { $0["reason"] != nil }?["reason"] as? String, "harassment")
        XCTAssertEqual(bodies.first { $0["reason"] != nil }?["description"] as? String, "rude")
    }

    func testUnreadTotalReadStatusAndBlockedList() async {
        let chat = service()
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/v1/chat/conversations/unread-total":
                return TestFixtures.envelopedResponse(json: "{\"unread_conversations\": 2, \"unread_messages\": 5, \"by_account\": []}")
            case "/v1/chat/conversations/\(self.conversationId)/read-status":
                return TestFixtures.envelopedResponse(json: "{\"statuses\": [{\"user_id\": \"\(self.them)\", \"last_read_at\": \"2026-11-24T10:00:00Z\"}, {\"user_id\": \"\(self.me)\", \"last_read_at\": null}]}")
            default:
                XCTAssertEqual(request.url?.path, "/v1/chat/users/blocks")
                return TestFixtures.envelopedResponse(json: "{\"blocked_user_ids\": [\"\(self.them)\"]}")
            }
        }
        let total = assertApiSuccess(await chat.unreadTotal())
        XCTAssertEqual(total?.unreadMessages, 5)
        let statuses = assertApiSuccess(await chat.readStatus(conversationId: conversationId))
        XCTAssertNotNil(statuses?.first?.lastReadDate)
        XCTAssertNil(statuses?.last?.lastReadDate)
        let blocked = assertApiSuccess(await chat.blockedUserIds())
        XCTAssertEqual(blocked, [them])
    }

    func testBlockMissingAddsOnlyWhatChatDoesNotHave() async {
        let chat = service()
        var blocked: [String] = []
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "GET" {
                return TestFixtures.envelopedResponse(json: "{\"blocked_user_ids\": [\"\(self.them.uppercased())\"]}")
            }
            blocked.append(request.url?.lastPathComponent == "block" ? request.url!.pathComponents[4] : "?")
            return TestFixtures.envelopedResponse(json: "null")
        }
        let added = await chat.blockMissing([them, me])
        XCTAssertEqual(added, 1)
        XCTAssertEqual(blocked, [me])
        let none = await chat.blockMissing([])
        XCTAssertEqual(none, 0)
    }
}
