import Foundation

/// A conversation in ScaleMule Chat. A direct conversation is between two
/// people; `counterpartyUserId` is the other one.
public struct ChatConversation: Sendable, Decodable, Identifiable, Equatable {
    public let id: String
    /// "direct", "group", "channel" and so on.
    public let conversationType: String
    public let name: String?
    public var participantCount: Int
    /// ISO 8601; nil when nobody has written yet.
    public var lastMessageAt: String?
    public var unreadCount: Int
    public var lastMessagePreview: String?
    public var lastMessageSenderId: String?
    /// "text", "image", "file".
    public var lastMessageType: String?
    public let counterpartyUserId: String?
    public var isMuted: Bool
    public let createdAt: String

    public init(
        id: String, conversationType: String = "direct", name: String? = nil, participantCount: Int = 2,
        lastMessageAt: String? = nil, unreadCount: Int = 0, lastMessagePreview: String? = nil,
        lastMessageSenderId: String? = nil, lastMessageType: String? = nil, counterpartyUserId: String? = nil,
        isMuted: Bool = false, createdAt: String = ""
    ) {
        self.id = id
        self.conversationType = conversationType
        self.name = name
        self.participantCount = participantCount
        self.lastMessageAt = lastMessageAt
        self.unreadCount = unreadCount
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageSenderId = lastMessageSenderId
        self.lastMessageType = lastMessageType
        self.counterpartyUserId = counterpartyUserId
        self.isMuted = isMuted
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name
        case conversationType = "conversation_type"
        case participantCount = "participant_count"
        case lastMessageAt = "last_message_at"
        case unreadCount = "unread_count"
        case lastMessagePreview = "last_message_preview"
        case lastMessageSenderId = "last_message_sender_id"
        case lastMessageType = "last_message_type"
        case counterpartyUserId = "counterparty_user_id"
        case isMuted = "is_muted"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        conversationType = try c.decodeIfPresent(String.self, forKey: .conversationType) ?? "direct"
        name = try c.decodeIfPresent(String.self, forKey: .name)
        participantCount = try c.decodeIfPresent(Int.self, forKey: .participantCount) ?? 0
        lastMessageAt = try c.decodeIfPresent(String.self, forKey: .lastMessageAt)
        unreadCount = try c.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
        lastMessagePreview = try c.decodeIfPresent(String.self, forKey: .lastMessagePreview).map(ChatText.unescape)
        lastMessageSenderId = try c.decodeIfPresent(String.self, forKey: .lastMessageSenderId)
        lastMessageType = try c.decodeIfPresent(String.self, forKey: .lastMessageType)
        counterpartyUserId = try c.decodeIfPresent(String.self, forKey: .counterpartyUserId)
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }

    public var isDirect: Bool { conversationType == "direct" }
    public var lastMessageDate: Date? { lastMessageAt.flatMap(ChatDate.parse) }
}

/// A file sent with a message.
public struct ChatAttachment: Sendable, Decodable, Equatable {
    public let fileId: String
    public let fileName: String
    public let fileSize: Int
    public let mimeType: String
    /// A link that works for a short time.
    public let url: String?
    public let thumbnailURL: String?

    private enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case fileName = "file_name"
        case fileSize = "file_size"
        case mimeType = "mime_type"
        case url = "presigned_url"
        case thumbnailURL = "thumbnail_url"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileId = try c.decode(String.self, forKey: .fileId)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        fileSize = try c.decodeIfPresent(Int.self, forKey: .fileSize) ?? 0
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url)
        thumbnailURL = try c.decodeIfPresent(String.self, forKey: .thumbnailURL)
    }

    public var isImage: Bool { mimeType.hasPrefix("image/") }
}

/// One emoji on a message and who added it.
public struct ChatReaction: Sendable, Decodable, Equatable {
    public let emoji: String
    public var count: Int
    public var userIds: [String]

    public init(emoji: String, count: Int, userIds: [String]) {
        self.emoji = emoji
        self.count = count
        self.userIds = userIds
    }

    private enum CodingKeys: String, CodingKey {
        case emoji, count
        case userIds = "user_ids"
    }
}

/// A message in a conversation.
public struct ChatMessage: Sendable, Decodable, Identifiable, Equatable {
    /// Where a message written on this phone stands.
    public enum Delivery: Sendable, Equatable { case sent, sending, failed }

    public var id: String
    /// The text people see (the server keeps it escaped; this is unescaped).
    public var content: String
    /// "text", "image", "file", "system".
    public let messageType: String
    public let senderId: String
    public var attachments: [ChatAttachment]
    public var reactions: [ChatReaction]
    public var isDeleted: Bool
    public var isEdited: Bool
    /// ISO 8601.
    public let createdAt: String
    /// `.sending` and `.failed` only for messages written on this phone.
    public var delivery: Delivery = .sent

    public init(id: String, content: String, messageType: String = "text", senderId: String, createdAt: String, delivery: Delivery = .sent) {
        self.id = id
        self.content = content
        self.messageType = messageType
        self.senderId = senderId
        self.attachments = []
        self.reactions = []
        self.isDeleted = false
        self.isEdited = false
        self.createdAt = createdAt
        self.delivery = delivery
    }

    private enum CodingKeys: String, CodingKey {
        case id, content, attachments, reactions
        case messageId = "message_id"
        case contentFormat = "content_format"
        case plainText = "plain_text"
        case messageType = "message_type"
        case senderId = "sender_id"
        case isDeleted = "is_deleted"
        case isEdited = "is_edited"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try c.decodeIfPresent(String.self, forKey: .id) {
            id = value
        } else {
            id = try c.decode(String.self, forKey: .messageId)
        }
        let raw = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        let format = try c.decodeIfPresent(String.self, forKey: .contentFormat) ?? "plain"
        let plain = try c.decodeIfPresent(String.self, forKey: .plainText)
        // A formatted message (written on the web) is shown as its plain text.
        if format == "html", let plain, !plain.isEmpty {
            content = ChatText.unescape(plain)
        } else {
            content = ChatText.unescape(raw)
        }
        messageType = try c.decodeIfPresent(String.self, forKey: .messageType) ?? "text"
        senderId = try c.decodeIfPresent(String.self, forKey: .senderId) ?? ""
        attachments = (try? c.decodeIfPresent([ChatAttachment].self, forKey: .attachments)) ?? []
        reactions = (try? c.decodeIfPresent([ChatReaction].self, forKey: .reactions)) ?? []
        isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        isEdited = try c.decodeIfPresent(Bool.self, forKey: .isEdited) ?? false
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }

    public var createdDate: Date? { ChatDate.parse(createdAt) }
}

/// One page of a conversation, newest message first.
public struct ChatMessagesPage: Sendable, Decodable {
    public let messages: [ChatMessage]
    /// There are older (or, when asking `after`, newer) messages to fetch.
    public let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case messages
        case hasMore = "has_more"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

/// How much the signed-in person has not read.
public struct ChatUnreadTotal: Sendable, Decodable, Equatable {
    public let unreadConversations: Int
    public let unreadMessages: Int

    private enum CodingKeys: String, CodingKey {
        case unreadConversations = "unread_conversations"
        case unreadMessages = "unread_messages"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unreadConversations = try c.decodeIfPresent(Int.self, forKey: .unreadConversations) ?? 0
        unreadMessages = try c.decodeIfPresent(Int.self, forKey: .unreadMessages) ?? 0
    }
}

/// When someone in a conversation last read it.
public struct ChatReadStatus: Sendable, Decodable, Equatable {
    public let userId: String
    public let lastReadAt: String?

    private enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case lastReadAt = "last_read_at"
    }

    public var lastReadDate: Date? { lastReadAt.flatMap(ChatDate.parse) }
}

/// Why a message is reported; the Chat service accepts exactly these.
public enum ChatReportReason: String, Sendable, CaseIterable {
    case spam, harassment, hate, violence, other
}

enum ChatDate {
    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func text(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Chat keeps people's text HTML-escaped (`it&#x27;s`); people see the text.
enum ChatText {
    static func unescape(_ value: String) -> String {
        guard value.contains("&") else { return value }
        return value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#x2F;", with: "/")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// User ids arrive with or without hyphens and in either case.
enum ChatID {
    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        return key(a) == key(b)
    }

    static func key(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
