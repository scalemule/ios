import Foundation
import ScaleMuleCore

/// Connections between people (`/v1/social-policy`): ask someone to connect,
/// answer requests, and see who you are connected with. In an app whose
/// ScaleMule policy is `connections_only`, Chat lets two people message only
/// once they are connected; a request is the one thing a stranger can send,
/// and ScaleMule caps how many a person sends per day.
///
/// The caller is always the signed-in person.
public final class ConnectionsService: ServiceModule, @unchecked Sendable {
    public let client: HTTPClient

    /// The longest note sent with a request (the app's own limit may be lower).
    public static let maxNoteLength = 300

    public required init(client: HTTPClient) {
        self.client = client
    }

    public convenience init(app: ScaleMuleApp) {
        self.init(client: app.client)
    }

    private let base = "/v1/social-policy"

    /// What I am to this person. A server without connection rules answers
    /// "not found": that reads as `ConnectionState.open`.
    public func state(with userId: String) async -> ApiResponse<ConnectionState> {
        let result: ApiResponse<ConnectionState> = await client.request(RequestOptions(
            method: .get, path: "\(base)/connections/\(userId)", credential: .accessToken
        ))
        if case .failure(let error) = result, error.statusCode == 404 { return .success(.open) }
        return result
    }

    /// Ask someone to connect, with an optional short note. Safe to repeat:
    /// a second ask returns the first request. If they had already asked me,
    /// the two are connected (`isConnected`).
    public func request(userId: String, note: String? = nil) async -> ApiResponse<ConnectionRequestResult> {
        var body: [String: Any] = ["target_identity_id": userId, "request_type": "connect_request"]
        let text = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { body["intro_message"] = String(text.prefix(Self.maxNoteLength)) }
        return await client.request(RequestOptions(
            method: .post, path: "\(base)/contact-requests", body: body, credential: .accessToken, retryable: false
        ))
    }

    /// Requests waiting for my answer, newest first.
    public func incoming(limit: Int = 50, before: String? = nil) async -> ApiResponse<[ConnectionRequest]> {
        await list("inbox", limit: limit, before: before)
    }

    /// Requests I sent that have not been answered, newest first.
    public func sent(limit: Int = 50, before: String? = nil) async -> ApiResponse<[ConnectionRequest]> {
        await list("sent", limit: limit, before: before)
    }

    private func list(_ which: String, limit: Int, before: String?) async -> ApiResponse<[ConnectionRequest]> {
        var query = ["status": "pending", "limit": String(min(max(limit, 1), 100))]
        if let before { query["before"] = before }
        return await client.request(RequestOptions(
            method: .get, path: "\(base)/contact-requests/\(which)", query: query, credential: .accessToken
        ))
    }

    public func accept(requestId: String) async -> ApiResponse<ConnectionRequestResult> {
        await answer(requestId, "accept")
    }

    /// Say no. The sender is not told.
    public func decline(requestId: String) async -> ApiResponse<ConnectionRequestResult> {
        await answer(requestId, "decline")
    }

    /// Say no and tell ScaleMule the request was abusive.
    public func report(requestId: String) async -> ApiResponse<ConnectionRequestResult> {
        await answer(requestId, "report")
    }

    private func answer(_ requestId: String, _ verb: String) async -> ApiResponse<ConnectionRequestResult> {
        await client.request(RequestOptions(
            method: .post, path: "\(base)/contact-requests/\(requestId)/\(verb)", body: [String: Any](), credential: .accessToken
        ))
    }

    /// Take back a request I sent.
    public func withdraw(requestId: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(method: .delete, path: "\(base)/contact-requests/\(requestId)", credential: .accessToken))
    }

    /// The people I am connected with, newest first.
    public func connections(limit: Int = 50, before: String? = nil) async -> ApiResponse<ConnectionsPage> {
        var query = ["limit": String(min(max(limit, 1), 100))]
        if let before { query["before"] = before }
        return await client.request(RequestOptions(method: .get, path: "\(base)/connections", query: query, credential: .accessToken))
    }

    /// End a connection. Either person can; the other is not told.
    public func remove(userId: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(method: .delete, path: "\(base)/connections/\(userId)", credential: .accessToken))
    }
}
