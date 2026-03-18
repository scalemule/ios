import Foundation

public enum ApiResponse<T: Sendable>: Sendable {
    case success(T)
    case failure(ApiError)

    public var data: T? {
        if case .success(let value) = self { return value }
        return nil
    }

    public var error: ApiError? {
        if case .failure(let err) = self { return err }
        return nil
    }

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

public struct ApiError: Error, Sendable, Equatable {
    public let code: ErrorCode
    public let message: String
    public let statusCode: Int?
    public let details: [String: AnyCodable]?

    public init(code: ErrorCode, message: String, statusCode: Int? = nil, details: [String: AnyCodable]? = nil) {
        self.code = code
        self.message = message
        self.statusCode = statusCode
        self.details = details
    }

    public static func network(_ message: String) -> ApiError {
        ApiError(code: .networkError, message: message)
    }

    public static func timeout() -> ApiError {
        ApiError(code: .timeout, message: "Request timed out")
    }

    public static func unauthorized(_ message: String = "Unauthorized") -> ApiError {
        ApiError(code: .unauthorized, message: message, statusCode: 401)
    }
}

struct ErrorResponse: Decodable {
    let error: String?
    let code: String?
    let message: String?
    let details: [String: AnyCodable]?
}

/// Backend envelope: `{ "success": bool, "data": T?, "error": ..., "meta": ... }`
struct BackendEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: BackendErrorDetail?
    let meta: BackendMeta?
}

struct BackendErrorDetail: Decodable {
    let code: String?
    let message: String?
    let field: String?
}

struct BackendMeta: Decodable {
    let timestamp: String?
    let requestId: String?

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case requestId = "request_id"
    }
}
