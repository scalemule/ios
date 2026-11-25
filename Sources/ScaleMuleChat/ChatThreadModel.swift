import Foundation
import Combine
import ScaleMuleCore
import ScaleMuleRealtime

/// One direct conversation, for a chat screen: its messages (oldest first),
/// sending with the message shown at once, the other person's typing and
/// "seen", older pages, delete and report. Messages arrive live over
/// `RealtimeClient`; after a dropped connection the model fetches what it
/// missed.
///
/// Make one per screen with the other person's id; `start()` when the screen
/// appears, `stop()` when it goes.
@MainActor
public final class ChatThreadModel: ObservableObject {
    /// Oldest first.
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasLoaded = false
    @Published public private(set) var hasOlder = false
    @Published public private(set) var isLoadingOlder = false
    @Published public private(set) var otherIsTyping = false
    /// When the other person last read the conversation.
    @Published public private(set) var otherLastRead: Date?
    /// The server refused the last send because one of the two blocked the other.
    @Published public private(set) var cannotMessage = false
    @Published public var errorMessage: String?

    public let peerUserId: String
    public let myUserId: String
    public private(set) var conversation: ChatConversation?
    /// The longest message `send` accepts.
    public var maxLength = 2000

    private let chat: ChatService
    private let realtime: RealtimeClient?
    private weak var inbox: ChatInboxModel?
    private let now: () -> Date

    private var channel: RealtimeSubscription?
    private var events: RealtimeSubscription?
    private var reconnects: AnyCancellable?
    private var isOnScreen = false
    private var typingOff: Task<Void, Never>?
    private var lastTypingSent: Date?
    private var sentTyping = false

    public init(
        peerUserId: String,
        myUserId: String,
        chat: ChatService,
        realtime: RealtimeClient?,
        inbox: ChatInboxModel? = nil,
        conversation: ChatConversation? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.peerUserId = peerUserId
        self.myUserId = myUserId
        self.chat = chat
        self.realtime = realtime
        self.inbox = inbox
        self.conversation = conversation ?? inbox?.conversation(with: peerUserId)
        self.now = now
    }

    // MARK: - On and off screen

    public func start() async {
        isOnScreen = true
        guard !hasLoaded, !isLoading else {
            listen()
            await markRead()
            return
        }
        isLoading = true
        defer { isLoading = false }
        guard await findConversation(), let id = conversation?.id else { return }
        listen()
        switch await chat.messages(conversationId: id) {
        case .success(let page):
            merge(page.messages.reversed())
            hasOlder = page.hasMore
            hasLoaded = true
            errorMessage = nil
        case .failure(let error):
            errorMessage = error.userFacingMessage
            return
        }
        if case .success(let statuses) = await chat.readStatus(conversationId: id) {
            noteRead(statuses.first { !ChatID.same($0.userId, myUserId) }?.lastReadDate)
        }
        await markRead()
    }

    public func stop() {
        isOnScreen = false
        if inbox?.openConversationId == conversation?.id { inbox?.openConversationId = nil }
        channel?.cancel()
        channel = nil
        events?.cancel()
        events = nil
        reconnects = nil
        typingOff?.cancel()
        otherIsTyping = false
        stopTyping()
    }

    private func findConversation() async -> Bool {
        if conversation != nil { return true }
        switch await chat.directConversation(with: peerUserId) {
        case .success(let found):
            conversation = found
            return true
        case .failure(let error):
            errorMessage = error.userFacingMessage
            return false
        }
    }

    private func listen() {
        guard let id = conversation?.id else { return }
        inbox?.openConversationId = id
        guard let realtime, events == nil else { return }
        channel = realtime.subscribe("conversation:\(id)")
        events = realtime.onEvent { [weak self] event in self?.handle(event) }
        reconnects = realtime.$connectionCount
            .dropFirst()
            .filter { $0 > 1 }
            .sink { [weak self] _ in Task { await self?.catchUp() } }
    }

    private func markRead() async {
        guard isOnScreen, let id = conversation?.id else { return }
        inbox?.noteRead(conversationId: id)
        guard messages.contains(where: { !isMine($0) }) else { return }
        _ = await chat.markRead(conversationId: id)
    }

    // MARK: - Reading

    public func isMine(_ message: ChatMessage) -> Bool {
        ChatID.same(message.senderId, myUserId)
    }

    /// The latest message of mine the other person has read: "Seen" goes under it.
    public var seenMessageId: String? {
        guard let otherLastRead else { return nil }
        return messages.last { message in
            guard isMine(message), message.delivery == .sent, !message.isDeleted, let sent = message.createdDate else { return false }
            return sent <= otherLastRead
        }?.id
    }

    public func loadOlder() async {
        guard hasOlder, !isLoadingOlder, let id = conversation?.id,
              let oldest = messages.first(where: { $0.delivery == .sent })?.id else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        switch await chat.messages(conversationId: id, before: oldest) {
        case .success(let page):
            let known = Set(messages.map(\.id))
            messages.insert(contentsOf: page.messages.reversed().filter { !known.contains($0.id) }, at: 0)
            hasOlder = page.hasMore
        case .failure(let error):
            errorMessage = error.userFacingMessage
        }
    }

    /// What arrived while the connection was down.
    func catchUp() async {
        guard hasLoaded, let id = conversation?.id else { return }
        guard let newest = messages.last(where: { $0.delivery == .sent })?.id else {
            if case .success(let page) = await chat.messages(conversationId: id) { merge(page.messages.reversed()) }
            return
        }
        var cursor = newest
        // `after` pages run oldest first; a long absence takes a few pages.
        for _ in 0..<5 {
            guard case .success(let page) = await chat.messages(conversationId: id, limit: 100, after: cursor), let last = page.messages.last else { break }
            merge(page.messages)
            cursor = last.id
            if !page.hasMore { break }
        }
        await markRead()
    }

    /// Add messages (oldest first) that are not here yet.
    private func merge<S: Sequence>(_ incoming: S) where S.Element == ChatMessage {
        for message in incoming { add(message) }
    }

    private func add(_ message: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            var kept = message
            kept.delivery = .sent
            if messages[index] != kept { messages[index] = kept }
            return
        }
        // My own message, announced before the send call answered.
        if isMine(message), let index = messages.firstIndex(where: { $0.delivery == .sending && $0.content == message.content }) {
            messages[index] = message
            return
        }
        // Keep what is still being sent below what has arrived.
        let firstUnsent = messages.firstIndex { $0.delivery != .sent } ?? messages.endIndex
        messages.insert(message, at: firstUnsent)
    }

    // MARK: - Writing

    /// Send `text`. The message shows at once as `.sending`; a failure leaves
    /// it as `.failed` for `retry` or `discard`.
    @discardableResult
    public func send(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.count <= maxLength else {
            errorMessage = "That message is too long. Keep it under \(maxLength) characters."
            return false
        }
        let local = ChatMessage(id: "local-\(UUID().uuidString)", content: trimmed, senderId: myUserId, createdAt: ChatDate.text(now()), delivery: .sending)
        messages.append(local)
        sentTyping = false
        lastTypingSent = nil
        return await deliver(localId: local.id, text: trimmed)
    }

    /// Try a failed message again.
    @discardableResult
    public func retry(_ message: ChatMessage) async -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == message.id && $0.delivery == .failed }) else { return false }
        messages[index].delivery = .sending
        return await deliver(localId: message.id, text: message.content)
    }

    /// Drop a message that failed to send.
    public func discard(_ message: ChatMessage) {
        messages.removeAll { $0.id == message.id && $0.delivery == .failed }
    }

    private func deliver(localId: String, text: String) async -> Bool {
        guard await findConversation(), let conversation else {
            fail(localId)
            return false
        }
        listen()
        switch await chat.send(conversationId: conversation.id, text: text) {
        case .success(let sent):
            if messages.contains(where: { $0.id == sent.id }) {
                // The live event got here first and took the local one's place.
                messages.removeAll { $0.id == localId }
            } else if let index = messages.firstIndex(where: { $0.id == localId }) {
                messages[index] = sent
            } else {
                add(sent)
            }
            hasLoaded = true
            cannotMessage = false
            errorMessage = nil
            inbox?.noteSent(sent, in: conversation)
            return true
        case .failure(let error):
            fail(localId)
            if error.statusCode == 403 {
                cannotMessage = true
                errorMessage = "You can't send messages to this person."
            } else {
                errorMessage = error.userFacingMessage
            }
            return false
        }
    }

    private func fail(_ localId: String) {
        guard let index = messages.firstIndex(where: { $0.id == localId }) else { return }
        messages[index].delivery = .failed
    }

    /// Delete one of my messages for both people.
    @discardableResult
    public func delete(_ message: ChatMessage) async -> Bool {
        guard isMine(message), message.delivery == .sent else {
            discard(message)
            return true
        }
        switch await chat.deleteMessage(id: message.id) {
        case .success:
            messages.removeAll { $0.id == message.id }
            return true
        case .failure(let error):
            errorMessage = error.userFacingMessage
            return false
        }
    }

    @discardableResult
    public func report(_ message: ChatMessage, reason: ChatReportReason, description: String? = nil) async -> Bool {
        switch await chat.report(messageId: message.id, reason: reason, description: description) {
        case .success:
            return true
        case .failure(let error):
            errorMessage = error.userFacingMessage
            return false
        }
    }

    /// Call as the text box changes: tells the other person I am typing, at
    /// most once every few seconds, and that I stopped when the box empties.
    public func typingChanged(hasText: Bool) {
        guard let id = conversation?.id, hasLoaded else { return }
        if hasText {
            if let lastTypingSent, now().timeIntervalSince(lastTypingSent) < 3 { return }
            lastTypingSent = now()
            sentTyping = true
            Task { _ = await chat.setTyping(conversationId: id, isTyping: true) }
        } else {
            stopTyping()
        }
    }

    private func stopTyping() {
        guard sentTyping, let id = conversation?.id else { return }
        sentTyping = false
        lastTypingSent = nil
        Task { _ = await chat.setTyping(conversationId: id, isTyping: false) }
    }

    // MARK: - Live events

    private struct Fields: Decodable {
        let conversationId: String?
        let userId: String?
        let messageId: String?
        let id: String?
        let lastReadAt: String?
        let content: String?
        let newContent: String?
        let plainText: String?
        let newPlainText: String?

        enum CodingKeys: String, CodingKey {
            case id, content
            case conversationId = "conversation_id"
            case userId = "user_id"
            case messageId = "message_id"
            case lastReadAt = "last_read_at"
            case newContent = "new_content"
            case plainText = "plain_text"
            case newPlainText = "new_plain_text"
        }
    }

    func handle(_ event: RealtimeEvent) {
        guard let id = conversation?.id, let fields = event.decode(Fields.self) else { return }
        // The conversation's channel, or my own channel naming this conversation.
        let mine = event.channel == "conversation:\(id)" || (event.channel.hasPrefix("private:") && fields.conversationId == id)
        guard mine else { return }
        switch event.name {
        case "new_message":
            guard let message = event.decode(ChatMessage.self) else { return }
            let isNew = !messages.contains { $0.id == message.id }
            add(message)
            if isNew, !isMine(message) {
                setOtherTyping(false)
                Task { await markRead() }
            }
        case "message_deleted":
            guard let messageId = fields.messageId ?? fields.id else { return }
            messages.removeAll { $0.id == messageId }
        case "message_edited":
            guard let messageId = fields.messageId ?? fields.id,
                  let index = messages.firstIndex(where: { $0.id == messageId }),
                  let text = fields.newPlainText ?? fields.plainText ?? fields.newContent ?? fields.content else { return }
            messages[index].content = ChatText.unescape(text)
            messages[index].isEdited = true
        case "messages_read":
            guard !ChatID.same(fields.userId, myUserId) else { return }
            noteRead(fields.lastReadAt.flatMap(ChatDate.parse))
        case "user_typing":
            guard !ChatID.same(fields.userId, myUserId) else { return }
            setOtherTyping(true)
        case "user_stopped_typing":
            guard !ChatID.same(fields.userId, myUserId) else { return }
            setOtherTyping(false)
        default:
            break
        }
    }

    private func noteRead(_ date: Date?) {
        guard let date, date > (otherLastRead ?? .distantPast) else { return }
        otherLastRead = date
    }

    private func setOtherTyping(_ typing: Bool) {
        typingOff?.cancel()
        if otherIsTyping != typing { otherIsTyping = typing }
        guard typing else { return }
        // A phone that goes away never says it stopped.
        typingOff = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.otherIsTyping = false
        }
    }
}
