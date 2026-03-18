import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

public struct RequestOptions: @unchecked Sendable {
    public let method: HTTPMethod
    public let path: String
    public let body: [String: Any]?
    public let query: [String: String]?
    public let credential: CredentialStrategy
    public let idempotent: Bool

    public init(
        method: HTTPMethod,
        path: String,
        body: [String: Any]? = nil,
        query: [String: String]? = nil,
        credential: CredentialStrategy = .accessToken,
        idempotent: Bool = false
    ) {
        self.method = method
        self.path = path
        self.body = body
        self.query = query
        self.credential = credential
        self.idempotent = idempotent
    }
}
