import Foundation
import ScaleMuleCore

// MARK: - Types

/// A record that belongs to a shared entity (an entry of a pet's health
/// record). It belongs to the entity, not to the person who wrote it: when
/// that person stops managing the entity the record stays, and everyone who
/// manages the entity works on the same records.
public struct EntityRecord: Sendable, Decodable, Identifiable, Equatable {
    public let id: String
    public let entityId: String
    public let collection: String
    /// The app-defined fields of the record.
    public let data: [String: AnyCodable]
    /// Raised by every change. Send it back with a change to detect that
    /// someone else changed the record in between.
    public let version: Int
    /// The person who wrote it; nil when the app's server did. Names and
    /// photos come from the profile service: fetch them for the page in one call.
    public let createdBy: String?
    public let updatedBy: String?
    public let createdAt: String
    public let updatedAt: String

    /// A text field, or nil when absent or not text.
    public func string(_ name: String) -> String? {
        data[name]?.value as? String
    }

    private enum CodingKeys: String, CodingKey {
        case id, collection, data, version
        case entityId = "entity_id"
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        entityId = try c.decodeIfPresent(String.self, forKey: .entityId) ?? ""
        collection = try c.decodeIfPresent(String.self, forKey: .collection) ?? ""
        data = try c.decodeIfPresent([String: AnyCodable].self, forKey: .data) ?? [:]
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
        updatedBy = try c.decodeIfPresent(String.self, forKey: .updatedBy)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }

    /// A new record id (a version 7 UUID: ids sort by the time they were made).
    ///
    /// Make one when the person starts a new entry and pass it to `create`:
    /// if the answer is lost and the entry is saved again, the first record
    /// is returned instead of a second one being made.
    public static func newID(now: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let milliseconds = UInt64(max(0, now.timeIntervalSince1970) * 1000)
        for index in 0..<6 {
            bytes[index] = UInt8((milliseconds >> UInt64(8 * (5 - index))) & 0xFF)
        }
        var generator = SystemRandomNumberGenerator()
        for index in 6..<16 {
            bytes[index] = UInt8.random(in: 0...255, using: &generator)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }
        return [
            hex[0..<4].joined(), hex[4..<6].joined(), hex[6..<8].joined(),
            hex[8..<10].joined(), hex[10..<16].joined(),
        ].joined(separator: "-")
    }
}

/// One page of an entity's records, newest first.
public struct EntityRecordPage: Sendable, Decodable {
    public let records: [EntityRecord]
    /// Pass as `before` to get the next (older) page; nil on the last page.
    public let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case records
        case nextCursor = "next_cursor"
    }
}

// MARK: - Service

/// Records that belong to a shared entity, kept in a collection the app
/// declared for that kind of entity (for example `health` for pets).
///
/// What the signed-in person may do is their role on the entity, compared
/// with the roles the collection asks for; by default a viewer reads, and a
/// member adds, changes and deletes. A refusal carries a stable `rawCode`
/// (`EntityErrorCode`) and a `message` that can be shown as is. A person who
/// no longer manages the entity gets `ENTITY_NOT_FOUND`.
public final class EntityRecordsService: ServiceModule {
    public let client: HTTPClient

    public required init(client: HTTPClient) {
        self.client = client
    }

    private func path(_ entityId: String, _ collection: String, _ recordId: String? = nil) -> String {
        let base = "/v1/data/entities/\(entityId)/\(collection)/documents"
        guard let recordId else { return base }
        return "\(base)/\(recordId)"
    }

    /// Add a record.
    ///
    /// `id` makes the call safe to repeat: saving the same entry again with
    /// the same id returns the first record. Pass the id you made with
    /// `EntityRecord.newID()` when the entry was started; without one the SDK
    /// makes one for this call, which still covers its own retries.
    public func create(
        entityId: String,
        collection: String,
        data: [String: Any],
        id: String? = nil
    ) async -> ApiResponse<EntityRecord> {
        await client.request(RequestOptions(
            method: .post,
            path: path(entityId, collection),
            body: ["id": id ?? EntityRecord.newID(), "data": data],
            credential: .accessToken
        ))
    }

    /// The entity's records in a collection, newest first.
    public func list(
        entityId: String,
        collection: String,
        before: String? = nil,
        limit: Int? = nil
    ) async -> ApiResponse<EntityRecordPage> {
        var query: [String: String] = [:]
        if let before { query["before"] = before }
        if let limit { query["limit"] = String(limit) }

        return await client.request(RequestOptions(
            method: .get,
            path: path(entityId, collection),
            query: query.isEmpty ? nil : query,
            credential: .accessToken
        ))
    }

    /// Every record of the entity in a collection, following the pages.
    /// Stops at `maxPages` as a guard.
    public func all(entityId: String, collection: String, maxPages: Int = 20) async -> ApiResponse<[EntityRecord]> {
        var records: [EntityRecord] = []
        var before: String?
        for _ in 0..<max(1, maxPages) {
            switch await list(entityId: entityId, collection: collection, before: before, limit: 100) {
            case .failure(let error):
                return .failure(error)
            case .success(let page):
                records.append(contentsOf: page.records)
                guard let next = page.nextCursor else { return .success(records) }
                before = next
            }
        }
        return .success(records)
    }

    public func get(entityId: String, collection: String, id: String) async -> ApiResponse<EntityRecord> {
        await client.request(RequestOptions(
            method: .get,
            path: path(entityId, collection, id),
            credential: .accessToken
        ))
    }

    /// Change a record.
    ///
    /// - `data` is merged into the stored fields; pass `NSNull()` for a field
    ///   to remove it. Two people changing different fields both keep their
    ///   change.
    /// - `version`: the version the change was made on. When given and the
    ///   record changed since, the change is refused with
    ///   `ENTITY_RECORD_VERSION_CONFLICT` instead of overwriting the other one.
    public func update(
        entityId: String,
        collection: String,
        id: String,
        data: [String: Any],
        version: Int? = nil
    ) async -> ApiResponse<EntityRecord> {
        var body: [String: Any] = ["data": data]
        if let version { body["version"] = version }

        return await client.request(RequestOptions(
            method: .patch,
            path: path(entityId, collection, id),
            body: body,
            credential: .accessToken
        ))
    }

    public func delete(entityId: String, collection: String, id: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .delete,
            path: path(entityId, collection, id),
            credential: .accessToken
        ))
    }
}
