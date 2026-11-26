import Foundation
import ScaleMuleCore

// MARK: - Role

/// A person's role on a shared entity. Highest first: owner, admin, member, viewer.
///
/// - viewer: reads the card and the list of people, also when the entity is private.
/// - member: also edits the name and attributes.
/// - admin: also changes who can see it; invites, changes and removes members and viewers.
/// - owner: everything, including admins, new owners and deletion.
///
/// An owner's role is changed or ended only by that owner, and only while another owner remains.
public struct EntityRole: RawRepresentable, Hashable, Sendable, Codable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let owner = EntityRole(rawValue: "owner")
    public static let admin = EntityRole(rawValue: "admin")
    public static let member = EntityRole(rawValue: "member")
    public static let viewer = EntityRole(rawValue: "viewer")

    /// Roles an invitation can offer. An owner is made from someone who already joined.
    public static let invitable: [EntityRole] = [.admin, .member, .viewer]

    /// 4 for owner down to 1 for viewer; 0 for a role this SDK version does not know.
    public var rank: Int {
        switch rawValue {
        case "owner": return 4
        case "admin": return 3
        case "member": return 2
        case "viewer": return 1
        default: return 0
        }
    }

    public static func < (lhs: EntityRole, rhs: EntityRole) -> Bool {
        lhs.rank < rhs.rank
    }

    /// May edit the name and attributes.
    public var canEdit: Bool { rank >= EntityRole.member.rank }
    /// May change visibility and see open invitations.
    public var canManage: Bool { rank >= EntityRole.admin.rank }
    /// May delete the entity.
    public var canDelete: Bool { self == .owner }

    /// Whether a person with this role may invite someone as `role`.
    public func canInvite(as role: EntityRole) -> Bool {
        guard role != .owner, role.rank > 0 else { return false }
        if self == .owner { return true }
        return self == .admin && role < .admin
    }

    /// Whether a person with this role may change or remove another person who has `role`.
    /// Leaving, or lowering your own role, is always allowed while an owner remains.
    public func canChange(someoneWith role: EntityRole) -> Bool {
        guard role != .owner else { return false }
        if self == .owner { return true }
        return self == .admin && role < .admin
    }
}

// MARK: - Visibility

public enum EntityVisibility: String, Sendable, Codable {
    /// Only the people who manage it.
    case membersOnly = "private"
    /// Any signed-in person of the app may read the card.
    case everyone = "public"
}

// MARK: - Kind

/// A kind of shared entity the app offers (for example `pet`), with its limits.
public struct EntityKind: Sendable, Decodable, Equatable {
    public let kind: String
    public let displayName: String
    public let status: String
    public let endUserCreate: Bool
    public let defaultVisibility: String
    public let maxOwnedPerUser: Int
    public let maxMembers: Int
    public let maxPendingInvitations: Int
    public let invitationTtlHours: Int
    public let attributesMaxBytes: Int

    private enum CodingKeys: String, CodingKey {
        case kind
        case displayName = "display_name"
        case status
        case endUserCreate = "end_user_create"
        case defaultVisibility = "default_visibility"
        case maxOwnedPerUser = "max_owned_per_user"
        case maxMembers = "max_members"
        case maxPendingInvitations = "max_pending_invitations"
        case invitationTtlHours = "invitation_ttl_hours"
        case attributesMaxBytes = "attributes_max_bytes"
    }
}

// MARK: - Entity

/// The card of a shared entity: a thing one person created and several people manage together.
public struct Entity: Sendable, Decodable, Identifiable, Equatable {
    public let id: String
    public let kind: String
    public let name: String
    /// `private` or `public`; see `isPublic`.
    public let visibility: String
    /// Small app-defined fields (for a pet: species, breed, birthday, a photo id).
    public let attributes: [String: AnyCodable]
    public let memberCount: Int
    /// Raised by every edit of the card. Send it back with an edit to detect a conflict.
    public let version: Int
    public let createdBy: String
    public let createdAt: String
    public let updatedAt: String
    /// The signed-in person's role; nil when they do not manage this entity.
    public let myRole: EntityRole?

    public var isPublic: Bool { visibility == EntityVisibility.everyone.rawValue }

    /// A text attribute, or nil when absent or not text.
    public func string(_ name: String) -> String? {
        attributes[name]?.value as? String
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, visibility, attributes, version
        case memberCount = "member_count"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case myRole = "my_role"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        visibility = try c.decodeIfPresent(String.self, forKey: .visibility) ?? "private"
        attributes = try c.decodeIfPresent([String: AnyCodable].self, forKey: .attributes) ?? [:]
        memberCount = try c.decodeIfPresent(Int.self, forKey: .memberCount) ?? 0
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        myRole = try c.decodeIfPresent(EntityRole.self, forKey: .myRole)
    }
}

/// One page of the entities a person manages.
public struct EntityPage: Sendable, Decodable {
    public let entities: [Entity]
    /// Pass as `after` to get the next page; nil on the last page.
    public let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case entities
        case nextCursor = "next_cursor"
    }
}

// MARK: - People

/// A person who manages an entity. Names and photos come from the profile
/// service: fetch them for the whole list in one call.
public struct EntityMember: Sendable, Decodable, Identifiable, Equatable {
    public let userId: String
    public let role: EntityRole
    public let addedBy: String?
    public let joinedAt: String

    public var id: String { userId }

    private enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case role
        case addedBy = "added_by"
        case joinedAt = "joined_at"
    }
}

// MARK: - Invitations

/// A new invitation. `token` is shown only here: build the link or QR code
/// from it now. The server keeps only its hash.
public struct IssuedEntityInvitation: Sendable, Decodable, Identifiable, Equatable {
    public let id: String
    public let entityId: String
    public let role: EntityRole
    public let token: String
    public let inviteeUserId: String?
    public let expiresAt: String

    private enum CodingKeys: String, CodingKey {
        case id, role, token
        case entityId = "entity_id"
        case inviteeUserId = "invitee_user_id"
        case expiresAt = "expires_at"
    }
}

/// An open invitation of an entity, as its owners and admins see it.
public struct EntityInvitation: Sendable, Decodable, Identifiable, Equatable {
    public let id: String
    public let role: EntityRole
    /// Set when the invitation names a person; nil for a link.
    public let inviteeUserId: String?
    public let invitedBy: String
    public let expiresAt: String
    public let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case id, role
        case inviteeUserId = "invitee_user_id"
        case invitedBy = "invited_by"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }
}

/// An invitation addressed to the signed-in person.
public struct ReceivedEntityInvitation: Sendable, Decodable, Identifiable, Equatable {
    public let id: String
    public let role: EntityRole
    public let invitedBy: String
    public let expiresAt: String
    public let createdAt: String
    public let entityId: String
    public let kind: String
    public let name: String
    public let attributes: [String: AnyCodable]

    private enum CodingKeys: String, CodingKey {
        case id, role, kind, name, attributes
        case invitedBy = "invited_by"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
        case entityId = "entity_id"
    }
}

/// What an invitation offers, before the person accepts it.
public struct EntityInvitationPreview: Sendable, Decodable, Equatable {
    public let invitationId: String
    public let role: EntityRole
    public let invitedBy: String
    public let expiresAt: String
    public let entity: Entity
    /// The person already manages this entity; accepting changes nothing.
    public let alreadyMember: Bool

    private enum CodingKeys: String, CodingKey {
        case role, entity
        case invitationId = "invitation_id"
        case invitedBy = "invited_by"
        case expiresAt = "expires_at"
        case alreadyMember = "already_member"
    }
}

public struct AcceptedEntityInvitation: Sendable, Decodable, Equatable {
    public let entity: Entity
    /// True when the person already managed the entity: nothing changed and a
    /// link stays unused.
    public let alreadyMember: Bool

    private enum CodingKeys: String, CodingKey {
        case entity
        case alreadyMember = "already_member"
    }
}

// MARK: - Refusals

/// The `rawCode` values of `ApiError` this module's calls answer with. Each
/// error's `message` is a sentence a person can be shown.
public enum EntityErrorCode {
    public static let notFound = "ENTITY_NOT_FOUND"
    public static let notAMember = "ENTITY_NOT_A_MEMBER"
    public static let roleRequired = "ENTITY_ROLE_REQUIRED"
    public static let ownerProtected = "ENTITY_OWNER_PROTECTED"
    public static let lastOwner = "ENTITY_LAST_OWNER"
    public static let limitReached = "ENTITY_LIMIT_REACHED"
    public static let memberLimitReached = "ENTITY_MEMBER_LIMIT_REACHED"
    public static let invitationLimitReached = "ENTITY_INVITATION_LIMIT_REACHED"
    public static let invitationInvalid = "ENTITY_INVITATION_INVALID"
    public static let alreadyMember = "ENTITY_ALREADY_MEMBER"
    public static let memberNotFound = "ENTITY_MEMBER_NOT_FOUND"
    public static let versionConflict = "ENTITY_VERSION_CONFLICT"
    public static let kindNotAvailable = "ENTITY_KIND_NOT_AVAILABLE"
}
