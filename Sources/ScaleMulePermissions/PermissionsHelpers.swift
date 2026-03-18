import Foundation

/// P12: Client-side helper — check if a permission matrix grants access for a resource+action.
public func canPerform(matrix: PermissionMatrixResponse, resource: String, action: String) -> Bool {
    guard let resourcePerms = matrix.permissions[resource] else { return false }
    return resourcePerms[action] == "allow"
}
