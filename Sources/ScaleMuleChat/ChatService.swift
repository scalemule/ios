import Foundation
import ScaleMuleCore

/// ScaleMule Chat for the signed-in person: conversations, messages, read
/// state, typing, blocking and reporting. For screens, use `ChatInboxModel`
/// (the list of conversations) and `ChatThreadModel` (one conversation).
public struct ChatService: ServiceModule {
    public let client: HTTPClient

    public init(client: HTTPClient) {
        self.client = client
    }

    public init(app: ScaleMuleApp) {
        self.init(client: app.client)
    }

    // MARK: - Conversations

    /// The direct conversation with one person; made the first time, the
    /// same one every time after.
    public func directConversation(with userId: String) async -> ApiResponse<ChatConversation> {
        let result: ApiResponse<ChatConversation> = await client.request(RequestOptions(
            method: .post,
            path: "/v1/chat/conversations",
            body: ["conversation_type": "direct", "participant_ids": [userId]],
            credential: .accessToken
        ))
        guard case .success(let made) = result, made.counterpartyUserId == nil else { return result }
        return .success(ChatConversation(
            id: made.id, conversationType: made.conversationType, name: made.name,
            participantCount: made.participantCount, counterpartyUserId: userId, createdAt: made.createdAt
        ))
    }

    /// The person's conversations, most recent first. `type` narrows to one
    /// kind ("direct").
    public func conversations(page: Int = 1, perPage: Int = 50, type: String? = nil) async -> ApiResponse<[ChatConversation]> {
        var query = ["page": String(max(1, page)), "per_page": String(min(100, max(1, perPage)))]
        if let type { query["conversation_type"] = type }
        return await client.request(RequestOptions(method: .get, path: "/v1/chat/conversations", query: query, credential: .accessToken))
    }

    public func unreadTotal() async -> ApiResponse<ChatUnreadTotal> {
        await client.request(RequestOptions(method: .get, path: "/v1/chat/conversations/unread-total", credential: .accessToken))
    }

    public func mute(conversationId: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(method: .post, path: "/v1/chat/conversations/\(conversationId)/mute", credential: .accessToken))
    }

    public func unmute(conversationId: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(method: .delete, path: "/v1/chat/conversations/\(conversationId)/mute", credential: .accessToken))
    }

    // MARK: - Messages

    /// A page of messages, newest first. `before` (a message id) fetches
    /// older ones; `after` fetches what arrived since, oldest first.
    public func messages(conversationId: String, limit: Int = 50, before: String? = nil, after: String? = nil) async -> ApiResponse<ChatMessagesPage> {
        var query = ["limit": String(min(100, max(1, limit)))]
        if let before { query["before"] = before }
        if let after { query["after"] = after }
        return await client.request(RequestOptions(method: .get, path: "/v1/chat/conversations/\(conversationId)/messages", query: query, credential: .accessToken))
    }

    /// Send a text message. Not repeated by itself after a network error (it
    /// would arrive twice): the caller offers "try again".
    public func send(conversationId: String, text: String) async -> ApiResponse<ChatMessage> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/chat/conversations/\(conversationId)/messages",
            body: ["content": text, "content_format": "plain", "message_type": "text"],
            credential: .accessToken,
            retryable: false
        ))
    }

    public func deleteMessage(id: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(method: .delete, path: "/v1/chat/messages/\(id)", credential: .accessToken))
    }

    public func react(messageId: String, emoji: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(method: .post, path: "/v1/chat/messages/\(messageId)/reactions", body: ["emoji": emoji], credential: .accessToken))
    }

    public func removeReaction(messageId: String, emoji: String) async -> ApiResponse<EmptyResponse> {
        let encoded = emoji.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? emoji
        return await client.requestVoid(RequestOptions(method: .delete, path: "/v1/chat/messages/\(messageId)/reactions/\(encoded)", credential: .accessToken))
    }

    public func report(messageId: String, reason: ChatReportReason, description: String? = nil) async -> ApiResponse<EmptyResponse> {
        var body: [String: Any] = ["reason": reason.rawValue]
        if let description, !description.isEmpty { body["description"] = description }
        return await client.requestVoid(RequestOptions(method: .post, path: "/v1/chat/messages/\(messageId)/report", body: body, credential: .accessToken))
    }

    // MARK: - Read state and typing

    /// Everything in the conversation is read by the signed-in person.
    public func markRead(conversationId: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(method: .post, path: "/v1/chat/conversations/\(conversationId)/read", credential: .accessToken))
    }

    /// When each person in the conversation last read it.
    public func readStatus(conversationId: String) async -> ApiResponse<[ChatReadStatus]> {
        struct Wrapper: Decodable, Sendable { let statuses: [ChatReadStatus] }
        let result: ApiResponse<Wrapper> = await client.request(RequestOptions(method: .get, path: "/v1/chat/conversations/\(conversationId)/read-status", credential: .accessToken))
        switch result {
        case .success(let wrapper): return .success(wrapper.statuses)
        case .failure(let error): return .failure(error)
        }
    }

    public func setTyping(conversationId: String, isTyping: Bool) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .post,
            path: "/v1/chat/conversations/\(conversationId)/typing",
            body: ["is_typing": isTyping],
            credential: .accessToken,
            retryable: false
        ))
    }

    // MARK: - Blocking

    /// Neither person can send the other a direct message afterwards.
    public func block(userId: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(method: .post, path: "/v1/chat/users/\(userId)/block", credential: .accessToken))
    }

    public func unblock(userId: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(method: .delete, path: "/v1/chat/users/\(userId)/block", credential: .accessToken))
    }

    /// The people the signed-in person blocked in Chat.
    public func blockedUserIds() async -> ApiResponse<[String]> {
        struct Wrapper: Decodable, Sendable {
            let ids: [String]
            enum CodingKeys: String, CodingKey { case ids = "blocked_user_ids" }
        }
        let result: ApiResponse<Wrapper> = await client.request(RequestOptions(method: .get, path: "/v1/chat/users/blocks", credential: .accessToken))
        switch result {
        case .success(let wrapper): return .success(wrapper.ids)
        case .failure(let error): return .failure(error)
        }
    }

    /// Make Chat refuse direct messages with everyone in `userIds` (the
    /// app's own block list, for example ScaleMule Safety's): blocks those
    /// Chat does not have yet. Returns how many were added.
    @discardableResult
    public func blockMissing(_ userIds: Set<String>) async -> Int {
        guard !userIds.isEmpty, case .success(let known) = await blockedUserIds() else { return 0 }
        let have = Set(known.map(ChatID.key))
        var added = 0
        for userId in userIds.sorted() where !have.contains(ChatID.key(userId)) {
            if case .success = await block(userId: userId) { added += 1 }
        }
        return added
    }
}
