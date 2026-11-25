import Foundation
import Combine
import ScaleMuleCore
import ScaleMuleRealtime

/// The signed-in person's direct conversations, most recent first, with the
/// number of unread messages for a tab badge. New messages arrive live over
/// `RealtimeClient`; `load()` fetches the list (call it when the app comes
/// to the front and when the screen opens).
///
/// Conversations nobody has written in are left out, and so are those with
/// people in `blockedUserIds`.
@MainActor
public final class ChatInboxModel: ObservableObject {
    @Published public private(set) var conversations: [ChatConversation] = []
    /// Unread messages across the conversations shown.
    @Published public private(set) var unread = 0
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasLoaded = false
    @Published public var errorMessage: String?

    /// People whose conversations are hidden (the app's block list).
    public var blockedUserIds: Set<String> = [] {
        didSet { if blockedUserIds != oldValue { publish() } }
    }
    /// The conversation on screen: its new messages do not count as unread.
    public var openConversationId: String?

    private var all: [ChatConversation] = []
    private var chat: ChatService?
    private var myUserId: String?
    private var events: RealtimeSubscription?
    private var reconnects: AnyCancellable?
    private var loading: Task<Void, Never>?

    public init() {}

    /// Connect the model to the signed-in person. Call again after sign-in.
    public func attach(chat: ChatService, realtime: RealtimeClient?, myUserId: String) {
        self.chat = chat
        self.myUserId = myUserId
        events?.cancel()
        events = realtime?.onEvent { [weak self] event in self?.handle(event) }
        reconnects = realtime?.$connectionCount
            .dropFirst()
            .filter { $0 > 1 }
            .sink { [weak self] _ in Task { await self?.load() } }
    }

    /// Forget everything (sign-out).
    public func reset() {
        events?.cancel()
        events = nil
        reconnects = nil
        loading?.cancel()
        loading = nil
        chat = nil
        myUserId = nil
        all = []
        openConversationId = nil
        hasLoaded = false
        errorMessage = nil
        publish()
    }

    public func load() async {
        if let loading { return await loading.value }
        let task = Task { await fetch() }
        loading = task
        await task.value
        loading = nil
    }

    private func fetch() async {
        guard let chat else { return }
        isLoading = true
        defer { isLoading = false }
        switch await chat.conversations(perPage: 100, type: "direct") {
        case .success(let list):
            all = list
            hasLoaded = true
            errorMessage = nil
            publish()
        case .failure(let error):
            if !hasLoaded { errorMessage = error.userFacingMessage }
        }
    }

    /// The loaded conversation with this person, if there is one.
    public func conversation(with userId: String) -> ChatConversation? {
        all.first { $0.isDirect && ChatID.same($0.counterpartyUserId, userId) }
    }

    /// The person read this conversation (its screen is open).
    public func noteRead(conversationId: String) {
        guard let index = all.firstIndex(where: { $0.id == conversationId }), all[index].unreadCount != 0 else { return }
        all[index].unreadCount = 0
        publish()
    }

    /// The person sent `message` in `conversation`: show it at the top.
    public func noteSent(_ message: ChatMessage, in conversation: ChatConversation) {
        var row = all.first { $0.id == conversation.id } ?? conversation
        row.lastMessagePreview = message.content
        row.lastMessageAt = message.createdAt
        row.lastMessageSenderId = message.senderId
        row.lastMessageType = message.messageType
        all.removeAll { $0.id == conversation.id }
        all.insert(row, at: 0)
        publish()
    }

    /// Forget a conversation on this phone (after blocking its person).
    public func remove(conversationId: String) {
        all.removeAll { $0.id == conversationId }
        publish()
    }

    // MARK: - Live events

    private struct Incoming: Decodable {
        let conversationId: String?

        enum CodingKeys: String, CodingKey { case conversationId = "conversation_id" }
    }

    func handle(_ event: RealtimeEvent) {
        // Each person's own channel announces every message sent to them.
        guard event.channel.hasPrefix("private:"), event.name == "new_message",
              let conversationId = event.decode(Incoming.self)?.conversationId,
              let message = event.decode(ChatMessage.self) else { return }
        guard let index = all.firstIndex(where: { $0.id == conversationId }) else {
            // A conversation this phone has not seen yet.
            Task { await load() }
            return
        }
        var row = all.remove(at: index)
        row.lastMessagePreview = message.content
        row.lastMessageAt = message.createdAt
        row.lastMessageSenderId = message.senderId
        row.lastMessageType = message.messageType
        if !ChatID.same(message.senderId, myUserId), openConversationId != conversationId {
            row.unreadCount += 1
        }
        all.insert(row, at: 0)
        publish()
    }

    private func publish() {
        let blocked = Set(blockedUserIds.map(ChatID.key))
        let shown = all.filter { row in
            guard row.lastMessageAt != nil else { return false }
            if let other = row.counterpartyUserId, blocked.contains(ChatID.key(other)) { return false }
            return true
        }
        if shown != conversations { conversations = shown }
        let count = shown.reduce(0) { $0 + ($1.isMuted ? 0 : max(0, $1.unreadCount)) }
        if count != unread { unread = count }
    }
}
