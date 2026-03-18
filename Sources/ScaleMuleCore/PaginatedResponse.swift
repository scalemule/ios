import Foundation

public struct PaginatedResponse<T: Sendable & Decodable>: Sendable, Decodable {
    public let data: [T]
    public let metadata: PaginationMetadata?

    private enum CodingKeys: String, CodingKey {
        case data
        case metadata
    }
}

public struct PaginationMetadata: Sendable, Decodable, Equatable {
    public let total: Int
    public let page: Int
    public let perPage: Int
    public let totalPages: Int

    private enum CodingKeys: String, CodingKey {
        case total
        case page
        case perPage = "per_page"
        case totalPages = "total_pages"
    }
}
