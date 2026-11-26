import Foundation
import ScaleMuleCore

/// Shared entities: things in an app (a pet, a vehicle) that one person
/// creates and several people manage together.
///
/// One person has one account and any number of entities; an entity has one
/// or more people, each with an `EntityRole`. The app declares its kinds on
/// the platform; `kinds()` lists them with their limits.
///
/// Every call is made for the signed-in person. A refusal carries a stable
/// `rawCode` (`EntityErrorCode`) and a `message` that can be shown as is.
public final class EntitiesService: ServiceModule {
    public let client: HTTPClient

    public required init(client: HTTPClient) {
        self.client = client
    }

    // MARK: - Kinds

    /// The kinds this app offers, with their limits.
    public func kinds() async -> ApiResponse<[EntityKind]> {
        let result: ApiResponse<KindsEnvelope> = await client.request(RequestOptions(
            method: .get,
            path: "/v1/accounts/entity-kinds",
            credential: .accessToken
        ))
        return result.mapData(\.kinds)
    }

    // MARK: - Cards

    /// Create an entity; the signed-in person becomes its owner.
    ///
    /// `idempotencyKey` protects against a lost answer: repeat the call with
    /// the same key and the first entity is returned instead of a second one
    /// being made. Keep one key per thing the person is creating (for
    /// example, generate it when the form opens).
    public func create(
        kind: String,
        name: String,
        attributes: [String: Any] = [:],
        visibility: EntityVisibility? = nil,
        idempotencyKey: String
    ) async -> ApiResponse<Entity> {
        var body: [String: Any] = [
            "kind": kind,
            "name": name,
            "idempotency_key": idempotencyKey,
        ]
        if !attributes.isEmpty { body["attributes"] = attributes }
        if let visibility { body["visibility"] = visibility.rawValue }

        return await client.request(RequestOptions(
            method: .post,
            path: "/v1/accounts/entities",
            body: body,
            credential: .accessToken
        ))
    }

    /// The entities the signed-in person manages, oldest first within a kind.
    /// Pass the previous page's `nextCursor` as `after`.
    public func mine(kind: String? = nil, after: String? = nil, limit: Int? = nil) async -> ApiResponse<EntityPage> {
        var query: [String: String] = [:]
        if let kind { query["kind"] = kind }
        if let after { query["after"] = after }
        if let limit { query["limit"] = String(limit) }

        return await client.request(RequestOptions(
            method: .get,
            path: "/v1/accounts/entities",
            query: query.isEmpty ? nil : query,
            credential: .accessToken
        ))
    }

    /// Every entity of a kind the signed-in person manages, following the
    /// pages. Stops at `maxPages` as a guard.
    public func allMine(kind: String? = nil, maxPages: Int = 20) async -> ApiResponse<[Entity]> {
        var all: [Entity] = []
        var after: String?
        for _ in 0..<max(1, maxPages) {
            switch await mine(kind: kind, after: after, limit: 100) {
            case .failure(let error):
                return .failure(error)
            case .success(let page):
                all.append(contentsOf: page.entities)
                guard let next = page.nextCursor else { return .success(all) }
                after = next
            }
        }
        return .success(all)
    }

    /// One card. A private entity of other people answers `ENTITY_NOT_FOUND`.
    public func get(id: String) async -> ApiResponse<Entity> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/accounts/entities/\(id)",
            credential: .accessToken
        ))
    }

    /// Cards for a page of ids (a feed, a list of posts), in one call. Up to
    /// 100 ids. Ids the person may not see are left out; order is not kept.
    public func lookup(ids: [String]) async -> ApiResponse<[Entity]> {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return .success([]) }
        let result: ApiResponse<EntitiesEnvelope> = await client.request(RequestOptions(
            method: .post,
            path: "/v1/accounts/entities/lookup",
            body: ["ids": unique],
            credential: .accessToken
        ))
        return result.mapData(\.entities)
    }

    /// Edit the card.
    ///
    /// - `attributes` are merged into the stored ones at the top level; pass
    ///   `NSNull()` for a name to remove it. Two people editing different
    ///   fields do not overwrite each other.
    /// - `version`: the version the edit was made on. When given and someone
    ///   else changed the card since, the edit is refused with
    ///   `ENTITY_VERSION_CONFLICT` instead of overwriting their change.
    public func update(
        id: String,
        name: String? = nil,
        attributes: [String: Any]? = nil,
        visibility: EntityVisibility? = nil,
        version: Int? = nil
    ) async -> ApiResponse<Entity> {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let attributes { body["attributes"] = attributes }
        if let visibility { body["visibility"] = visibility.rawValue }
        if let version { body["version"] = version }

        return await client.request(RequestOptions(
            method: .patch,
            path: "/v1/accounts/entities/\(id)",
            body: body,
            credential: .accessToken
        ))
    }

    /// Delete the entity for everyone. Owners only.
    public func delete(id: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .delete,
            path: "/v1/accounts/entities/\(id)",
            credential: .accessToken
        ))
    }

    // MARK: - People

    /// The people who manage the entity, owners first.
    public func members(entityId: String) async -> ApiResponse<[EntityMember]> {
        let result: ApiResponse<MembersEnvelope> = await client.request(RequestOptions(
            method: .get,
            path: "/v1/accounts/entities/\(entityId)/members",
            credential: .accessToken
        ))
        return result.mapData(\.members)
    }

    /// Change a person's role. See `EntityRole` for who may change whom.
    public func setRole(entityId: String, userId: String, role: EntityRole) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .patch,
            path: "/v1/accounts/entities/\(entityId)/members/\(userId)",
            body: ["role": role.rawValue],
            credential: .accessToken
        ))
    }

    /// Remove a person. To leave, pass the signed-in person's own id.
    /// The only owner cannot leave: `ENTITY_LAST_OWNER`.
    public func removeMember(entityId: String, userId: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .delete,
            path: "/v1/accounts/entities/\(entityId)/members/\(userId)",
            credential: .accessToken
        ))
    }

    // MARK: - Inviting

    /// Invite someone.
    ///
    /// Without `inviteeUserId` the result is a link token: anyone signed in to
    /// the app can use it once. With it, the invitation works only for that
    /// person and appears in their `receivedInvitations()`.
    public func invite(
        entityId: String,
        role: EntityRole,
        inviteeUserId: String? = nil,
        expiresInHours: Int? = nil
    ) async -> ApiResponse<IssuedEntityInvitation> {
        var body: [String: Any] = ["role": role.rawValue]
        if let inviteeUserId { body["invitee_user_id"] = inviteeUserId }
        if let expiresInHours { body["expires_in_hours"] = expiresInHours }

        return await client.request(RequestOptions(
            method: .post,
            path: "/v1/accounts/entities/\(entityId)/invitations",
            body: body,
            credential: .accessToken,
            retryable: false
        ))
    }

    /// Open invitations of an entity. Owners and admins.
    public func invitations(entityId: String) async -> ApiResponse<[EntityInvitation]> {
        let result: ApiResponse<InvitationsEnvelope<EntityInvitation>> = await client.request(RequestOptions(
            method: .get,
            path: "/v1/accounts/entities/\(entityId)/invitations",
            credential: .accessToken
        ))
        return result.mapData(\.invitations)
    }

    /// Withdraw an open invitation. A person who already joined stays.
    public func revokeInvitation(entityId: String, invitationId: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .delete,
            path: "/v1/accounts/entities/\(entityId)/invitations/\(invitationId)",
            credential: .accessToken
        ))
    }

    // MARK: - Being invited

    /// Open invitations addressed to the signed-in person.
    public func receivedInvitations() async -> ApiResponse<[ReceivedEntityInvitation]> {
        let result: ApiResponse<InvitationsEnvelope<ReceivedEntityInvitation>> = await client.request(RequestOptions(
            method: .get,
            path: "/v1/accounts/entity-invitations",
            credential: .accessToken
        ))
        return result.mapData(\.invitations)
    }

    /// What a link offers, before accepting it.
    public func previewInvitation(token: String) async -> ApiResponse<EntityInvitationPreview> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/accounts/entity-invitations/preview",
            body: ["token": token],
            credential: .accessToken
        ))
    }

    /// Join through a link.
    public func acceptInvitation(token: String) async -> ApiResponse<AcceptedEntityInvitation> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/accounts/entity-invitations/accept",
            body: ["token": token],
            credential: .accessToken
        ))
    }

    /// Accept an invitation addressed to the signed-in person.
    public func acceptInvitation(id: String) async -> ApiResponse<AcceptedEntityInvitation> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/accounts/entity-invitations/\(id)/accept",
            credential: .accessToken
        ))
    }

    /// Decline an invitation addressed to the signed-in person.
    public func declineInvitation(id: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .post,
            path: "/v1/accounts/entity-invitations/\(id)/decline",
            credential: .accessToken
        ))
    }
}

// MARK: - Envelopes

private struct KindsEnvelope: Sendable, Decodable {
    let kinds: [EntityKind]
}

private struct EntitiesEnvelope: Sendable, Decodable {
    let entities: [Entity]
}

private struct MembersEnvelope: Sendable, Decodable {
    let members: [EntityMember]
}

private struct InvitationsEnvelope<T: Sendable & Decodable>: Sendable, Decodable {
    let invitations: [T]
}

private extension ApiResponse {
    func mapData<U: Sendable>(_ transform: (T) -> U) -> ApiResponse<U> {
        switch self {
        case .success(let value): return .success(transform(value))
        case .failure(let error): return .failure(error)
        }
    }
}
