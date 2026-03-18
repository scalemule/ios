import Foundation
import ScaleMuleCore

public final class PermissionsService: ServiceModule {
    public let client: HTTPClient

    public required init(client: HTTPClient) {
        self.client = client
    }

    // MARK: - P01: Create Role

    public func createRole(roleName: String, description: String? = nil) async -> ApiResponse<RoleResponse> {
        var body: [String: Any] = ["role_name": roleName]
        if let description { body["description"] = description }

        return await client.request(RequestOptions(
            method: .post,
            path: "/v1/permissions/roles",
            body: body,
            credential: .accessToken
        ))
    }

    // MARK: - P02: List Roles

    public func listRoles() async -> ApiResponse<[RoleResponse]> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/permissions/roles",
            credential: .accessToken
        ))
    }

    // MARK: - P03: Assign Permissions to Role

    public func assignPermissions(roleId: String, permissionIds: [String]) async -> ApiResponse<AssignPermissionsResponse> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/permissions/roles/\(roleId)/permissions",
            body: ["permission_ids": permissionIds],
            credential: .accessToken
        ))
    }

    // MARK: - P04: Assign Role to User

    public func assignRole(userId: String, roleId: String) async -> ApiResponse<UserRoleResponse> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/permissions/users/\(userId)/roles",
            body: ["role_id": roleId],
            credential: .accessToken
        ))
    }

    // MARK: - P05: Check Permission

    public func check(
        identityId: String? = nil,
        permission: String,
        identityType: String? = nil,
        resourceType: String? = nil,
        resourceId: String? = nil
    ) async -> ApiResponse<CheckPermissionResponse> {
        var body: [String: Any] = ["permission": permission]
        if let identityId { body["identity_id"] = identityId }
        if let identityType { body["identity_type"] = identityType }
        if let resourceType { body["resource_type"] = resourceType }
        if let resourceId { body["resource_id"] = resourceId }

        return await client.request(RequestOptions(
            method: .post,
            path: "/v1/permissions/check",
            body: body,
            credential: .accessToken
        ))
    }

    // MARK: - P06: Batch Check Permissions

    public func batchCheck(
        identityId: String? = nil,
        checks: [PermissionCheck],
        identityType: String? = nil
    ) async -> ApiResponse<BatchCheckResponse> {
        var body: [String: Any] = [
            "checks": checks.map(\.toDictionary),
        ]
        if let identityId { body["identity_id"] = identityId }
        if let identityType { body["identity_type"] = identityType }

        return await client.request(RequestOptions(
            method: .post,
            path: "/v1/permissions/batch-check",
            body: body,
            credential: .accessToken
        ))
    }

    // MARK: - P07: Get Permission Matrix

    public func getMatrix(identityId: String, identityType: String? = nil) async -> ApiResponse<PermissionMatrixResponse> {
        var query: [String: String] = ["identity_id": identityId]
        if let identityType { query["identity_type"] = identityType }

        return await client.request(RequestOptions(
            method: .get,
            path: "/v1/permissions/matrix",
            query: query,
            credential: .accessToken
        ))
    }

    // MARK: - P08: Get User Permissions

    public func getUserPermissions(userId: String) async -> ApiResponse<UserPermissionsResponse> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/permissions/users/\(userId)/permissions",
            credential: .accessToken
        ))
    }

    // MARK: - P09: Create Policy

    public func createPolicy(
        policyName: String,
        description: String? = nil,
        effect: String,
        resourcePattern: String,
        actionPattern: String,
        conditions: String? = nil,
        priority: Int? = nil,
        principals: [[String: String]]
    ) async -> ApiResponse<PolicyResponse> {
        var body: [String: Any] = [
            "policy_name": policyName,
            "effect": effect,
            "resource_pattern": resourcePattern,
            "action_pattern": actionPattern,
            "principals": principals,
        ]
        if let description { body["description"] = description }
        if let conditions { body["conditions"] = conditions }
        if let priority { body["priority"] = priority }

        return await client.request(RequestOptions(
            method: .post,
            path: "/v1/permissions/policies",
            body: body,
            credential: .accessToken
        ))
    }

    // MARK: - P10: List Policies

    public func listPolicies() async -> ApiResponse<[PolicyResponse]> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/permissions/policies",
            credential: .accessToken
        ))
    }

    // MARK: - P11: Evaluate Policy

    public func evaluate(
        userId: String,
        resource: String,
        action: String,
        context: [String: Any]? = nil
    ) async -> ApiResponse<EvaluatePolicyResponse> {
        var body: [String: Any] = [
            "user_id": userId,
            "resource": resource,
            "action": action,
        ]
        if let context { body["context"] = context }

        return await client.request(RequestOptions(
            method: .post,
            path: "/v1/permissions/evaluate",
            body: body,
            credential: .accessToken
        ))
    }
}
