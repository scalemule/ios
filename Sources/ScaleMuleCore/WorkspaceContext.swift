import Foundation

public actor WorkspaceContext {
    private var currentWorkspaceId: String?

    public var workspaceId: String? {
        currentWorkspaceId
    }

    public func set(_ workspaceId: String?) {
        currentWorkspaceId = workspaceId
    }
}
