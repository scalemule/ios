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
    /// A pre-encoded body (for example multipart form data). Takes the place of `body`.
    public let rawBody: Data?
    /// Content-Type for `rawBody`.
    public let contentType: String?
    /// Accept header. Defaults to `application/json`.
    public let accept: String?
    /// False for requests that must not be sent twice after a network error,
    /// timeout or server error (an upload creates a new record every time).
    public let retryable: Bool
    /// Extra request headers (for example `X-Upload-Session-Id`, which ties
    /// the server's logs to one upload).
    public let headers: [String: String]

    public init(
        method: HTTPMethod,
        path: String,
        body: [String: Any]? = nil,
        query: [String: String]? = nil,
        credential: CredentialStrategy = .accessToken,
        idempotent: Bool = false,
        rawBody: Data? = nil,
        contentType: String? = nil,
        accept: String? = nil,
        retryable: Bool = true,
        headers: [String: String] = [:]
    ) {
        self.method = method
        self.path = path
        self.body = body
        self.query = query
        self.credential = credential
        self.idempotent = idempotent
        self.rawBody = rawBody
        self.contentType = contentType
        self.accept = accept
        self.retryable = retryable
        self.headers = headers
    }
}

/// Builds a `multipart/form-data` body.
public struct MultipartFormData: Sendable {
    public let boundary: String
    private var data = Data()

    public init(boundary: String = "ScaleMule-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(Self.escape(name))\"\r\n\r\n")
        append(value)
        append("\r\n")
    }

    public mutating func addFile(name: String, filename: String, mimeType: String, data fileData: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(Self.escape(name))\"; filename=\"\(Self.escape(filename))\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        data.append(fileData)
        append("\r\n")
    }

    /// The finished body, including the closing boundary.
    public func encoded() -> Data {
        var result = data
        result.append(Data("--\(boundary)--\r\n".utf8))
        return result
    }

    private mutating func append(_ string: String) {
        data.append(Data(string.utf8))
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\"", with: "%22")
    }
}
