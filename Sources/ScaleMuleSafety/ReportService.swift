import Foundation
import ScaleMuleCore

/// What is being reported.
public enum ReportContentType: String, Sendable {
    case image, video, post, comment, audio, message, profile
    case discussionComment = "discussion_comment"
}

/// Why it is being reported. `childSafety` is reviewed first.
public enum ReportCategory: String, Sendable, CaseIterable {
    case nudity, violence, harassment, copyright, spam, misinformation, privacy, other
    case hateSpeech = "hate_speech"
    case illegalActivity = "illegal_activity"
    case selfHarm = "self_harm"
    case childSafety = "child_safety"
}

public struct ContentReport: Sendable, Decodable, Identifiable, Equatable {
    public let id: String
    public let contentType: String
    public let contentId: String
    public let category: String
    public let status: String
    public let priority: String?
    public let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case id, category, status, priority
        case contentType = "content_type"
        case contentId = "content_id"
        case createdAt = "created_at"
    }
}

/// Report content to ScaleMule moderation (`/v1/flagcontent`). The reporter
/// is always the signed-in person (signed out, only anonymous reports are
/// accepted). Reviewers hide or remove content in the owning service; an app
/// can also have content hidden automatically after a number of different
/// people report it (a per-app setting, off by default). Apps should still
/// hide reported content for the reporter straight away.
public final class ReportService: ServiceModule, @unchecked Sendable {
    public let client: HTTPClient

    public required init(client: HTTPClient) {
        self.client = client
    }

    public convenience init(app: ScaleMuleApp) {
        self.init(client: app.client)
    }

    public func report(
        _ contentType: ReportContentType,
        id contentId: String,
        category: ReportCategory,
        reporterId: String?,
        description: String? = nil,
        contentURL: String? = nil
    ) async -> ApiResponse<ContentReport> {
        var body: [String: Any] = [
            "content_type": contentType.rawValue,
            "content_id": contentId,
            "category": category.rawValue,
            "is_anonymous": false,
        ]
        // The server uses the session's person; a matching id is accepted for
        // older servers that read it from the body.
        if let reporterId { body["reporter_id"] = reporterId }
        if let description, !description.isEmpty { body["description"] = description }
        if let contentURL { body["content_url"] = contentURL }

        return await client.request(RequestOptions(
            method: .post,
            path: "/v1/flagcontent/flags",
            body: body,
            credential: .accessToken,
            retryable: false
        ))
    }
}
