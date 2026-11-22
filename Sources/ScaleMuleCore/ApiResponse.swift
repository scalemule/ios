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
    /// Extra fields the server sent with the error. For an envelope error that
    /// carries a `data` object (for example `LINK_REQUIRED`), these are its fields.
    public let details: [String: AnyCodable]?
    /// The exact `code` string the server returned, also when `code` could only
    /// be mapped to a generic case such as `.conflict` or `.forbidden`.
    public let rawCode: String?

    public init(
        code: ErrorCode,
        message: String,
        statusCode: Int? = nil,
        details: [String: AnyCodable]? = nil,
        rawCode: String? = nil
    ) {
        self.code = code
        self.message = message
        self.statusCode = statusCode
        self.details = details
        self.rawCode = rawCode ?? code.rawValue
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

// MARK: - Text for people

extension ApiError: LocalizedError {
    /// `localizedDescription` is the person-facing text, never "An internal error occurred".
    public var errorDescription: String? { userFacingMessage }

    /// Server codes for a request refused by the gateway's anti-abuse checks
    /// because of the network it came from.
    static let networkRefusedCodes: Set<String> = ["TRUST_SCORE_TOO_LOW", "IP_BLOCKED", "BLOCKED"]

    /// Text that is safe to show a person: it says what happened in plain
    /// words and what to do next. Server failures, network problems, rate
    /// limits and anti-abuse refusals get fixed wording; any other error keeps
    /// the server's own message, which is written for people.
    public var userFacingMessage: String {
        if let rawCode, Self.networkRefusedCodes.contains(rawCode) {
            return "We couldn't do that from the network you're on right now. Wait a few minutes and try again, or switch between Wi-Fi and mobile data."
        }
        switch code {
        case .networkError:
            return "You seem to be offline. Check your connection and try again."
        case .timeout:
            return "This is taking too long. Check your connection and try again."
        case .rateLimited:
            return "Too many tries. Wait a minute and try again."
        case .internalError, .unknown:
            if statusCode == nil || (statusCode ?? 0) >= 500 {
                return "Something went wrong on our side. Please try again in a minute."
            }
        default:
            break
        }
        if let statusCode, statusCode >= 500 {
            return "Something went wrong on our side. Please try again in a minute."
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Something went wrong. Please try again." : trimmed
    }
}
