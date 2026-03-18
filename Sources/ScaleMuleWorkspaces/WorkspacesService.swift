import Foundation
import ScaleMuleCore

public final class WorkspacesService: ServiceModule {
    public let client: HTTPClient

    public required init(client: HTTPClient) {
        self.client = client
    }

    // MARK: - W01: Create Workspace

    public func create(name: String, description: String? = nil) async -> ApiResponse<ContainerResponse> {
        var body: [String: Any] = ["name": name]
        if let description { body["description"] = description }

        return await client.request(RequestOptions(
            method: .post,
            path: "/v1/workspaces",
            body: body,
            credential: .accessToken
        ))
    }

    // MARK: - W02: List Workspaces

    /// Backend accepts page/perPage input but returns raw array without pagination metadata.
    public func list(page: Int? = nil, perPage: Int? = nil) async -> ApiResponse<[ContainerResponse]> {
        var query: [String: String] = [:]
        if let page { query["page"] = String(page) }
        if let perPage { query["per_page"] = String(perPage) }

        return await client.request(RequestOptions(
            method: .get,
            path: "/v1/workspaces",
            query: query.isEmpty ? nil : query,
            credential: .accessToken
        ))
    }

    // MARK: - W03: My Workspaces (with pagination)

    /// Only workspace endpoint with real pagination metadata.
    public func mine(page: Int? = nil, perPage: Int? = nil) async -> ApiResponse<PaginatedResponse<ContainerResponse>> {
        var query: [String: String] = [:]
        if let page { query["page"] = String(page) }
        if let perPage { query["per_page"] = String(perPage) }

        return await client.request(RequestOptions(
            method: .get,
            path: "/v1/workspaces/mine",
            query: query.isEmpty ? nil : query,
            credential: .accessToken
        ))
    }

    // MARK: - W04: Get Workspace

    public func get(id: String) async -> ApiResponse<ContainerResponse> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/workspaces/\(id)",
            credential: .accessToken
        ))
    }

    // MARK: - W05: Update Workspace

    public func update(id: String, name: String? = nil, description: String? = nil) async -> ApiResponse<ContainerResponse> {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let description { body["description"] = description }

        return await client.request(RequestOptions(
            method: .patch,
            path: "/v1/workspaces/\(id)",
            body: body.isEmpty ? nil : body,
            credential: .accessToken
        ))
    }

    // MARK: - W06: Delete Workspace (204 No Content)

    public func delete(id: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .delete,
            path: "/v1/workspaces/\(id)",
            credential: .accessToken
        ))
    }

    // MARK: - W07: List Members

    /// Supports `?hydrate=true` to enrich with profile fields (full_name, email, avatar_url).
    public func listMembers(workspaceId: String, hydrate: Bool? = nil) async -> ApiResponse<[MemberResponse]> {
        var query: [String: String] = [:]
        if let hydrate { query["hydrate"] = String(hydrate) }

        return await client.request(RequestOptions(
            method: .get,
            path: "/v1/workspaces/\(workspaceId)/members",
            query: query.isEmpty ? nil : query,
            credential: .accessToken
        ))
    }

    // MARK: - W08: Add Member

    public func addMember(workspaceId: String, userId: String, role: String? = nil) async -> ApiResponse<MemberResponse> {
        var body: [String: Any] = ["sm_user_id": userId]
        if let role { body["role"] = role }

        return await client.request(RequestOptions(
            method: .post,
            path: "/v1/workspaces/\(workspaceId)/members",
            body: body,
            credential: .accessToken
        ))
    }

    // MARK: - W09: Update Member

    public func updateMember(workspaceId: String, userId: String, role: String) async -> ApiResponse<MemberResponse> {
        await client.request(RequestOptions(
            method: .patch,
            path: "/v1/workspaces/\(workspaceId)/members/\(userId)",
            body: ["role": role],
            credential: .accessToken
        ))
    }

    // MARK: - W10: Remove Member (204 No Content)

    public func removeMember(workspaceId: String, userId: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .delete,
            path: "/v1/workspaces/\(workspaceId)/members/\(userId)",
            credential: .accessToken
        ))
    }

    // MARK: - W11: Invite

    public func invite(workspaceId: String, email: String, role: String? = nil) async -> ApiResponse<InvitationResponse> {
        var body: [String: Any] = ["email": email]
        if let role { body["role"] = role }

        return await client.request(RequestOptions(
            method: .post,
            path: "/v1/workspaces/\(workspaceId)/invitations",
            body: body,
            credential: .accessToken
        ))
    }

    // MARK: - W12: List Invitations

    public func listInvitations(workspaceId: String) async -> ApiResponse<[InvitationResponse]> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/workspaces/\(workspaceId)/invitations",
            credential: .accessToken
        ))
    }

    // MARK: - W13: Accept Invitation

    public func acceptInvitation(token: String) async -> ApiResponse<InvitationResponse> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/workspaces/invitations/\(token)/accept",
            credential: .accessToken
        ))
    }

    // MARK: - W14: Cancel Invitation (204 No Content)

    public func cancelInvitation(id: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .delete,
            path: "/v1/workspaces/invitations/\(id)",
            credential: .accessToken
        ))
    }

    // MARK: - W15: Configure SSO

    public func configureSso(workspaceId: String, config: ConfigureSsoRequest) async -> ApiResponse<SsoConfigurationResponse> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/workspaces/\(workspaceId)/sso/configure",
            body: config.toDictionary,
            credential: .accessToken
        ))
    }

    // MARK: - W16: Get SSO Configuration

    public func getSso(workspaceId: String) async -> ApiResponse<SsoConfigurationResponse> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/workspaces/\(workspaceId)/sso",
            credential: .accessToken
        ))
    }
}
