import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMulePermissions

final class PermissionsServiceTests: XCTestCase {
    func testCreateRole() async {
        let (app, _) = createTestClient()
        let permissions = PermissionsService(client: app.client)

        let creds = CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600))
        try? await app.sessionManager.setCredentials(creds)

        MockURLProtocol.requestHandler = { request in
            let body = self.bodyJSON(request)!
            // Backend expects role_name, not name
            XCTAssertEqual(body["role_name"] as? String, "admin")
            XCTAssertNil(body["name"])
            return TestFixtures.mockResponse(json: TestFixtures.roleJSON)
        }

        let result = await permissions.createRole(roleName: "admin", description: "Administrator")
        let role = assertApiSuccess(result)
        XCTAssertEqual(role?.roleName, "admin")
    }

    func testCheckPermission() async {
        let (app, _) = createTestClient()
        let permissions = PermissionsService(client: app.client)

        let creds = CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600))
        try? await app.sessionManager.setCredentials(creds)

        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(json: TestFixtures.checkPermissionJSON)
        }

        let result = await permissions.check(
            identityId: "usr_abc123",
            permission: "read",
            resourceType: "document",
            resourceId: "doc_1"
        )
        let check = assertApiSuccess(result)
        XCTAssertTrue(check?.granted ?? false)
    }

    func testBatchCheck() async {
        let (app, _) = createTestClient()
        let permissions = PermissionsService(client: app.client)

        let creds = CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600))
        try? await app.sessionManager.setCredentials(creds)

        MockURLProtocol.requestHandler = { request in
            let body = self.bodyJSON(request)!
            // Backend expects checks array of objects, not permissions array of strings
            let checks = body["checks"] as? [[String: Any]]
            XCTAssertNotNil(checks)
            XCTAssertEqual(checks?.count, 2)
            XCTAssertNil(body["permissions"])

            return TestFixtures.mockResponse(json: """
            {"results": [
                {"permission": "read", "granted": true, "resource_type": null, "resource_id": null},
                {"permission": "write", "granted": false, "resource_type": null, "resource_id": null}
            ]}
            """)
        }

        let result = await permissions.batchCheck(
            identityId: "usr_abc123",
            checks: [
                PermissionCheck(permission: "read"),
                PermissionCheck(permission: "write"),
            ]
        )
        let batch = assertApiSuccess(result)
        XCTAssertEqual(batch?.results.count, 2)
        XCTAssertTrue(batch?.results[0].granted ?? false)
        XCTAssertFalse(batch?.results[1].granted ?? true)
    }

    func testEvaluatePolicy() async {
        let (app, _) = createTestClient()
        let permissions = PermissionsService(client: app.client)

        let creds = CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600))
        try? await app.sessionManager.setCredentials(creds)

        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(json: """
            {"decision": "allow", "matched_policies": ["policy_1"], "reason": "Role match", "evaluation_time_ms": 1.5}
            """)
        }

        let result = await permissions.evaluate(
            userId: "usr_abc123",
            resource: "document:doc_1",
            action: "read"
        )
        let evaluation = assertApiSuccess(result)
        XCTAssertEqual(evaluation?.decision, "allow")
        XCTAssertEqual(evaluation?.matchedPolicies, ["policy_1"])
    }
}
