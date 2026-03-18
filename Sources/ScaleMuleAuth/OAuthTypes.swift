import Foundation

public struct OAuthUrl: Sendable, Decodable {
    public let url: String
    public let state: String?
}

public enum OAuthProvider: String, Sendable, Codable {
    case google
    case github
    case apple
    case microsoft
    case facebook
    case twitter
    case linkedin
    case custom
}

public struct LinkedProvider: Sendable, Decodable {
    public let provider: String
    public let providerId: String?
    public let email: String?
    public let linkedAt: String?

    private enum CodingKeys: String, CodingKey {
        case provider
        case providerId = "provider_id"
        case email
        case linkedAt = "linked_at"
    }
}

public struct ListLinkedProvidersResult: Sendable, Decodable {
    public let providers: [LinkedProvider]
}
