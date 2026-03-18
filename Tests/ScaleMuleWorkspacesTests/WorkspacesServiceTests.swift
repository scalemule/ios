import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleWorkspaces

final class WorkspacesServiceTests: XCTestCase {
    func testCreateWorkspace() async {
        let (app, _) = createTestClient()
        let workspaces = WorkspacesService(client: app.client)

        let creds = CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600))
        try? await app.sessionManager.setCredentials(creds)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["name"] as? String, "My Workspace")
            return TestFixtures.mockResponse(json: TestFixtures.workspaceJSON)
        }

        let result = await workspaces.create(name: "My Workspace", description: "A test workspace")
        let ws = assertApiSuccess(result)
        XCTAssertEqual(ws?.name, "Test Workspace")
    }

    func testListWorkspacesReturnsRawArray() async {
        let (app, _) = createTestClient()
        let workspaces = WorkspacesService(client: app.client)

        let creds = CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600))
        try? await app.sessionManager.setCredentials(creds)

        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(json: "[\(TestFixtures.workspaceJSON)]")
        }

        let result = await workspaces.list()
        let list = assertApiSuccess(result)
        XCTAssertEqual(list?.count, 1)
    }

    func testDeleteWorkspaceReturns204() async {
        let (app, _) = createTestClient()
        let workspaces = WorkspacesService(client: app.client)

        let creds = CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600))
        try? await app.sessionManager.setCredentials(creds)

        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.scalemule.com")!,
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let result = await workspaces.delete(id: "ws_1")
        XCTAssertTrue(result.isSuccess)
    }

    func testListMembersWithHydrate() async {
        let (app, _) = createTestClient()
        let workspaces = WorkspacesService(client: app.client)

        let creds = CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600))
        try? await app.sessionManager.setCredentials(creds)

        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            XCTAssertTrue(url.query?.contains("hydrate=true") ?? false)
            return TestFixtures.mockResponse(json: "[\(TestFixtures.memberJSON)]")
        }

        let result = await workspaces.listMembers(workspaceId: "ws_1", hydrate: true)
        let members = assertApiSuccess(result)
        XCTAssertEqual(members?.count, 1)
        XCTAssertEqual(members?.first?.fullName, "Test User")
    }

    func testRemoveMemberReturns204() async {
        let (app, _) = createTestClient()
        let workspaces = WorkspacesService(client: app.client)

        let creds = CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600))
        try? await app.sessionManager.setCredentials(creds)

        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.scalemule.com")!,
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let result = await workspaces.removeMember(workspaceId: "ws_1", userId: "usr_abc123")
        XCTAssertTrue(result.isSuccess)
    }

    func testInvite() async {
        let (app, _) = createTestClient()
        let workspaces = WorkspacesService(client: app.client)

        let creds = CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600))
        try? await app.sessionManager.setCredentials(creds)

        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(json: TestFixtures.invitationJSON)
        }

        let result = await workspaces.invite(workspaceId: "ws_1", email: "invite@example.com", role: "member")
        let inv = assertApiSuccess(result)
        XCTAssertEqual(inv?.email, "invite@example.com")
        XCTAssertEqual(inv?.status, "pending")
    }
}
