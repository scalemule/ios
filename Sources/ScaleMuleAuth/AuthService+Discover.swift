import Foundation
import ScaleMuleCore

/// Discover response — cross-app discovery, NOT part of Firehosy MVP.
public struct DiscoverResult: Sendable, Decodable {
    public let providers: [String]?
    public let methods: [String]?
    public let requiresVerification: Bool?

    private enum CodingKeys: String, CodingKey {
        case providers
        case methods
        case requiresVerification = "requires_verification"
    }
}

extension AuthService {
    // MARK: - A01: Discover (Optional)

    /// Discover available auth methods for an email. Not part of Firehosy MVP.
    public func discover(email: String) async -> ApiResponse<DiscoverResult> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/discover",
            body: ["email": email],
            credential: .none
        ))
    }
}
