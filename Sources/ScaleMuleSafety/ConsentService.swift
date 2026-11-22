import Foundation
import CryptoKit
import ScaleMuleCore

/// One consent the person gave or refused (ScaleMule Compliance, `/v1/compliance/consent/v2`).
public struct ConsentRecord: Sendable, Decodable, Identifiable, Equatable {
    public let id: String
    public let smUserId: String
    public let purposeId: String
    public let purposeCode: String
    public let consentGiven: Bool
    public let collectionPoint: String?
    public let grantedAt: String?
    public let withdrawnAt: String?
    public let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case smUserId = "sm_user_id"
        case purposeId = "purpose_id"
        case purposeCode = "purpose_code"
        case consentGiven = "consent_given"
        case collectionPoint = "collection_point"
        case grantedAt = "granted_at"
        case withdrawnAt = "withdrawn_at"
        case createdAt = "created_at"
    }
}

struct ConsentList: Decodable, Sendable {
    let consents: [ConsentRecord]
}

/// Record that a person accepted a versioned document (Terms, Privacy
/// Policy, a content licence) and check it later from any device.
///
/// The server keeps every record and does not return document versions on
/// read, so the version is part of the purpose code: `terms@2026-11-21`.
/// Accepting a new version is a new record.
public final class ConsentService: ServiceModule, @unchecked Sendable {
    public let client: HTTPClient

    public required init(client: HTTPClient) {
        self.client = client
    }

    public convenience init(app: ScaleMuleApp) {
        self.init(client: app.client)
    }

    /// `code@version`, the purpose code stored for a versioned document.
    public static func versionedCode(_ code: String, version: String) -> String {
        "\(code)@\(version)"
    }

    /// A stable UUID (version 5) for a purpose code, so every app and device
    /// files the same document under the same purpose id.
    public static func purposeId(for code: String) -> String {
        // RFC 4122 URL namespace.
        let namespace: [UInt8] = [0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8]
        var digest = Array(Insecure.SHA1.hash(data: Data(namespace + Array("scalemule-consent:\(code)".utf8))))
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20).prefix(12)]
        return parts.joined(separator: "-")
    }

    /// Record one decision for the signed-in person (`userId` must be theirs).
    public func record(
        userId: String,
        code: String,
        version: String,
        given: Bool = true,
        collectionPoint: String,
        privacyPolicyVersion: String? = nil
    ) async -> ApiResponse<ConsentRecord> {
        let purposeCode = Self.versionedCode(code, version: version)
        var body: [String: Any] = [
            "sm_user_id": userId,
            "purpose_id": Self.purposeId(for: code),
            "purpose_code": purposeCode,
            "consent_given": given,
            "consent_method": "explicit",
            "collection_point": String(collectionPoint.prefix(200)),
            "consent_text_version": String(version.prefix(50)),
        ]
        if let privacyPolicyVersion { body["privacy_policy_version"] = String(privacyPolicyVersion.prefix(50)) }

        return await client.request(RequestOptions(
            method: .post,
            path: "/v1/compliance/consent/v2",
            body: body,
            credential: .accessToken,
            retryable: false
        ))
    }

    /// Every consent record for the person, newest first.
    public func list(userId: String) async -> ApiResponse<[ConsentRecord]> {
        let result: ApiResponse<ConsentList> = await client.request(RequestOptions(
            method: .get,
            path: "/v1/compliance/consent/v2/\(userId)",
            credential: .accessToken
        ))
        switch result {
        case .success(let list): return .success(list.consents)
        case .failure(let error): return .failure(error)
        }
    }

    /// The versioned documents (`code@version`) the person has accepted and
    /// not withdrawn, judged by their newest record for each.
    public static func accepted(in records: [ConsentRecord]) -> Set<String> {
        var latest: [String: ConsentRecord] = [:]
        for record in records where latest[record.purposeCode] == nil || (record.createdAt ?? "") > (latest[record.purposeCode]?.createdAt ?? "") {
            latest[record.purposeCode] = record
        }
        return Set(latest.values.filter { $0.consentGiven && $0.withdrawnAt == nil }.map(\.purposeCode))
    }
}
