import Foundation
import ScaleMuleCore

/// What the signed-in person is to someone else, and what they may do next.
///
/// Each app sets its own rule in ScaleMule (`direct_message_policy`): with
/// `connections_only` two people must be connected before they can message;
/// with `open` anyone who is not blocked can. Screens should read
/// `canMessage` and `canRequest`, not the policy.
public struct ConnectionState: Sendable, Equatable, Decodable {
    public enum Kind: String, Sendable {
        case none
        case connected
        /// I asked; they have not answered (a silent "no" also reads like this).
        case requestSent = "request_sent"
        /// They asked me.
        case requestReceived = "request_received"
        /// One of the two blocked the other.
        case unavailable
    }

    public var kind: Kind
    /// The pending request, when there is one.
    public var requestId: String?
    public var canMessage: Bool
    public var canRequest: Bool

    public init(kind: Kind, requestId: String? = nil, canMessage: Bool, canRequest: Bool) {
        self.kind = kind
        self.requestId = requestId
        self.canMessage = canMessage
        self.canRequest = canRequest
    }

    /// An app (or an older server) with no connection rule: messages are open.
    public static let open = ConnectionState(kind: .none, canMessage: true, canRequest: false)

    private enum CodingKeys: String, CodingKey {
        case state
        case requestId = "request_id"
        case canMessage = "can_message"
        case canRequest = "can_request"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = Kind(rawValue: (try? c.decode(String.self, forKey: .state)) ?? "") ?? .none
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
        canMessage = try c.decodeIfPresent(Bool.self, forKey: .canMessage) ?? (kind == .connected)
        canRequest = try c.decodeIfPresent(Bool.self, forKey: .canRequest) ?? (kind == .none)
    }
}

/// A request to connect, as its sender or its receiver sees it.
public struct ConnectionRequest: Sendable, Equatable, Identifiable, Decodable {
    public let id: String
    public let fromUserId: String
    public let toUserId: String
    /// A short note from the sender, as they typed it. Show as plain text.
    public let note: String?
    public let status: String
    public let createdAt: String?

    public var createdDate: Date? { createdAt.flatMap(ConnectionDate.parse) }
    public var isPending: Bool { status == "pending" }

    public init(id: String, fromUserId: String, toUserId: String, note: String? = nil, status: String = "pending", createdAt: String? = nil) {
        self.id = id
        self.fromUserId = fromUserId
        self.toUserId = toUserId
        self.note = note
        self.status = status
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, status
        case fromUserId = "actor_identity_id"
        case toUserId = "target_identity_id"
        case note = "intro_message"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        fromUserId = try c.decode(String.self, forKey: .fromUserId)
        toUserId = try c.decode(String.self, forKey: .toUserId)
        let text = try c.decodeIfPresent(String.self, forKey: .note)?.trimmingCharacters(in: .whitespacesAndNewlines)
        note = (text?.isEmpty ?? true) ? nil : text
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }
}

/// The answer to sending a request.
public struct ConnectionRequestResult: Sendable, Equatable, Decodable {
    public let id: String
    public let status: String

    /// The other person had already asked: the two are now connected.
    public var isConnected: Bool { status == "accepted" }
}

/// Someone the signed-in person is connected with.
public struct Connection: Sendable, Equatable, Identifiable, Decodable {
    public let userId: String
    public let connectedAt: String?

    public var id: String { userId }
    public var connectedDate: Date? { connectedAt.flatMap(ConnectionDate.parse) }

    private enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case connectedAt = "connected_at"
    }
}

public struct ConnectionsPage: Sendable, Equatable, Decodable {
    public let connections: [Connection]
    public let hasMore: Bool
    /// Pass as `before` for the next page; nil on the last one.
    public let nextBefore: String?

    private enum CodingKeys: String, CodingKey {
        case connections
        case hasMore = "has_more"
        case nextBefore = "next_before"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connections = try c.decodeIfPresent([Connection].self, forKey: .connections) ?? []
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        nextBefore = try c.decodeIfPresent(String.self, forKey: .nextBefore)
    }
}

enum ConnectionDate {
    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// User ids arrive with or without hyphens and in either case.
enum ConnectionID {
    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        return key(a) == key(b)
    }

    static func key(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
