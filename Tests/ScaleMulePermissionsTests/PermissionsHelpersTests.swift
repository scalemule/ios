import XCTest
@testable import ScaleMulePermissions

final class PermissionsHelpersTests: XCTestCase {
    func testCanPerformGranted() {
        let matrix = PermissionMatrixResponse(
            identityId: "usr_1",
            identityType: "user",
            policyVersion: "v1",
            permissions: [
                "document": ["read": "allow", "write": "deny"],
                "folder": ["read": "allow"],
            ]
        )
        XCTAssertTrue(canPerform(matrix: matrix, resource: "document", action: "read"))
        XCTAssertFalse(canPerform(matrix: matrix, resource: "document", action: "write"))
        XCTAssertFalse(canPerform(matrix: matrix, resource: "document", action: "delete"))
        XCTAssertFalse(canPerform(matrix: matrix, resource: "unknown", action: "read"))
    }
}
