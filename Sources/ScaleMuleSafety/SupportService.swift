import Foundation
import ScaleMuleCore

public enum SupportMessageType: String, Sendable {
    case bugReport = "bug_report"
    case featureRequest = "feature_request"
    case improvement
    case other
}

public struct SupportMessage: Sendable, Decodable, Identifiable, Equatable {
    public let id: String
    public let type: String
    public let title: String
    public let status: String
    public let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case id, type, title, status
        case createdAt = "created_at"
    }
}

/// Send a message to the app's team (ScaleMule Feedback, `/v1/feedback`).
/// The team reads and answers it in the ScaleMule portal; answers are
/// emailed. Works signed in (the account's email is used) or signed out
/// (pass `email`). The app must have feedback switched on.
public final class SupportService: ServiceModule, @unchecked Sendable {
    public let client: HTTPClient

    public required init(client: HTTPClient) {
        self.client = client
    }

    public convenience init(app: ScaleMuleApp) {
        self.init(client: app.client)
    }

    public func send(
        _ type: SupportMessageType = .other,
        title: String,
        message: String,
        email: String? = nil,
        tags: [String]? = nil
    ) async -> ApiResponse<SupportMessage> {
        var body: [String: Any] = [
            "type": type.rawValue,
            "title": String(title.prefix(255)),
            "description": message,
        ]
        if let email, !email.isEmpty { body["email"] = email }
        if let tags { body["tags"] = tags }
        return await client.request(RequestOptions(
            method: .post,
            path: "/v1/feedback/submit",
            body: body,
            credential: .accessToken,
            retryable: false
        ))
    }
}
