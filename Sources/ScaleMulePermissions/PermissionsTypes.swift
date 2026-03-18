import Foundation
import ScaleMuleCore

// MARK: - Roles

public struct RoleResponse: Sendable, Decodable {
    public let id: String
    public let smApplicationId: String?
    public let roleName: String
    public let description: String?
    public let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case smApplicationId = "sm_application_id"
        case roleName = "role_name"
        case description
        case createdAt = "created_at"
    }
}

public struct AssignPermissionsResponse: Sendable, Decodable {
    public let roleId: String
    public let permissionsAdded: Int

    private enum CodingKeys: String, CodingKey {
        case roleId = "role_id"
        case permissionsAdded = "permissions_added"
    }
}

public struct UserRoleResponse: Sendable, Decodable {
    public let id: String
    public let userId: String
    public let roleId: String
    public let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case roleId = "role_id"
        case createdAt = "created_at"
    }
}

// MARK: - Permission Checks

public struct CheckPermissionResponse: Sendable, Decodable {
    public let granted: Bool
    public let permission: String
    public let resourceType: String?
    public let resourceId: String?
    public let reason: String?

    private enum CodingKeys: String, CodingKey {
        case granted
        case permission
        case resourceType = "resource_type"
        case resourceId = "resource_id"
        case reason
    }
}

public struct BatchCheckResponse: Sendable, Decodable {
    public let results: [BatchCheckResult]
}

public struct BatchCheckResult: Sendable, Decodable {
    public let permission: String
    public let granted: Bool
    public let resourceType: String?
    public let resourceId: String?

    private enum CodingKeys: String, CodingKey {
        case permission
        case granted
        case resourceType = "resource_type"
        case resourceId = "resource_id"
    }
}

// MARK: - User Permissions

public struct UserPermissionsResponse: Sendable, Decodable {
    public let userId: String
    public let directPermissions: [String]
    public let rolePermissions: [String]
    public let totalPermissions: Int

    private enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case directPermissions = "direct_permissions"
        case rolePermissions = "role_permissions"
        case totalPermissions = "total_permissions"
    }
}

// MARK: - Policies

public struct PolicyResponse: Sendable, Decodable {
    public let id: String
    public let smApplicationId: String?
    public let policyName: String
    public let description: String?
    public let effect: String
    public let resourcePattern: String
    public let actionPattern: String
    public let conditions: String?
    public let priority: Int?
    public let isActive: Bool?
    public let principals: [PolicyPrincipal]?
    public let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case smApplicationId = "sm_application_id"
        case policyName = "policy_name"
        case description
        case effect
        case resourcePattern = "resource_pattern"
        case actionPattern = "action_pattern"
        case conditions
        case priority
        case isActive = "is_active"
        case principals
        case createdAt = "created_at"
    }
}

public struct PolicyPrincipal: Sendable, Decodable {
    public let principalType: String
    public let principalId: String

    private enum CodingKeys: String, CodingKey {
        case principalType = "principal_type"
        case principalId = "principal_id"
    }
}

// MARK: - Policy Evaluation

public struct EvaluatePolicyResponse: Sendable, Decodable {
    public let decision: String
    public let matchedPolicies: [String]?
    public let reason: String?
    public let evaluationTimeMs: Double?

    private enum CodingKeys: String, CodingKey {
        case decision
        case matchedPolicies = "matched_policies"
        case reason
        case evaluationTimeMs = "evaluation_time_ms"
    }
}

// MARK: - Permission Matrix

public struct PermissionMatrixResponse: Sendable, Decodable {
    public let identityId: String
    public let identityType: String?
    public let policyVersion: String?
    public let permissions: [String: [String: String]]

    private enum CodingKeys: String, CodingKey {
        case identityId = "identity_id"
        case identityType = "identity_type"
        case policyVersion = "policy_version"
        case permissions
    }
}

// MARK: - Batch Check Input

public struct PermissionCheck: Sendable {
    public let permission: String
    public let resourceType: String?
    public let resourceId: String?

    public init(permission: String, resourceType: String? = nil, resourceId: String? = nil) {
        self.permission = permission
        self.resourceType = resourceType
        self.resourceId = resourceId
    }

    var toDictionary: [String: Any] {
        var dict: [String: Any] = ["permission": permission]
        if let resourceType { dict["resource_type"] = resourceType }
        if let resourceId { dict["resource_id"] = resourceId }
        return dict
    }
}
