import Foundation

public enum TestFixtures {
    public static let userJSON = """
    {
        "id": "usr_abc123",
        "sm_application_id": "app_123",
        "email": "test@example.com",
        "phone": null,
        "username": "testuser",
        "full_name": "Test User",
        "avatar_url": null,
        "email_verified": true,
        "phone_verified": false,
        "mfa_enabled": false,
        "status": "active",
        "created_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z"
    }
    """

    /// Register returns User directly — no { "user": ... } wrapper
    public static let registerJSON = userJSON

    public static let loginJSON = """
    {
        "session_token": "sess_abc123",
        "user": \(userJSON),
        "expires_at": "2026-02-01T00:00:00Z",
        "absolute_expires_at": "2026-03-01T00:00:00Z",
        "access_token": null,
        "refresh_token": null,
        "access_token_expires_in": null,
        "device": {
            "id": "dev_123",
            "name": "iPhone 15",
            "trust_level": "low",
            "is_new": true
        },
        "risk": {
            "score": 10,
            "action": "allow",
            "factors": [],
            "action_required": false
        }
    }
    """

    public static let loginWithTokensJSON = """
    {
        "session_token": "sess_abc123",
        "user": \(userJSON),
        "expires_at": "2026-02-01T00:00:00Z",
        "absolute_expires_at": "2026-03-01T00:00:00Z",
        "access_token": "at_jwt_123",
        "refresh_token": "rt_abc123",
        "access_token_expires_in": 3600,
        "device": null,
        "risk": null
    }
    """

    public static let refreshSessionJSON = """
    {
        "session_token": "sess_refreshed_456",
        "expires_at": "2026-02-02T00:00:00Z"
    }
    """

    public static let verifyEmailJSON = """
    {
        "verified": true,
        "session_token": "sess_verify_789",
        "user": \(userJSON),
        "expires_at": "2026-02-01T00:00:00Z"
    }
    """

    /// Real backend wire format: error envelope with challenge JSON string in error.message
    public static let mfaChallengeJSON = """
    {
        "success": false,
        "error": {
            "code": "MFA_REQUIRED",
            "message": "{\\"pending_token\\":\\"mfa_pending_abc\\",\\"mfa_method\\":\\"totp\\",\\"expires_in\\":600,\\"allowed_methods\\":[\\"totp\\",\\"sms\\"]}"
        },
        "meta": {"timestamp": "2026-01-01T00:00:00Z", "request_id": "req_mfa"}
    }
    """

    public static let mfaVerifyJSON = """
    {
        "session_token": "sess_mfa_completed",
        "user": \(userJSON),
        "expires_at": "2026-02-01T00:00:00Z",
        "access_token": null,
        "refresh_token": null,
        "access_token_expires_in": null
    }
    """

    public static let messageJSON = """
    {"message": "Success"}
    """

    public static let sessionsListJSON = """
    {
        "sessions": [
            {
                "id": "sess_1",
                "user_id": "usr_abc123",
                "ip_address": "192.168.1.1",
                "user_agent": "ScaleMule-SDK-Swift/0.0.1",
                "last_active_at": "2026-01-01T00:00:00Z",
                "created_at": "2026-01-01T00:00:00Z",
                "expires_at": "2026-02-01T00:00:00Z",
                "is_current": true
            }
        ],
        "total": 1
    }
    """

    public static let devicesListJSON = """
    {
        "devices": [
            {
                "id": "dev_1",
                "user_id": "usr_abc123",
                "fingerprint": "fp_abc",
                "name": "iPhone",
                "trusted": true,
                "blocked": false,
                "last_seen_at": "2026-01-01T00:00:00Z",
                "created_at": "2026-01-01T00:00:00Z"
            }
        ],
        "total": 1
    }
    """

    public static let loginHistoryJSON = """
    {
        "entries": [
            {
                "id": "lh_1",
                "user_id": "usr_abc123",
                "ip_address": "192.168.1.1",
                "user_agent": "Test",
                "success": true,
                "failure_reason": null,
                "location": "New York",
                "device_fingerprint": "fp_abc",
                "created_at": "2026-01-01T00:00:00Z"
            }
        ],
        "total": 1,
        "page": 1,
        "per_page": 20
    }
    """

    public static let roleJSON = """
    {
        "id": "role_1",
        "sm_application_id": "app_123",
        "role_name": "admin",
        "description": "Administrator",
        "created_at": "2026-01-01T00:00:00Z"
    }
    """

    public static let checkPermissionJSON = """
    {
        "granted": true,
        "permission": "read",
        "resource_type": "document",
        "resource_id": "doc_1",
        "reason": "Role-based access"
    }
    """

    public static let workspaceJSON = """
    {
        "id": "ws_1",
        "sm_application_id": "app_123",
        "kind": "workspace",
        "name": "Test Workspace",
        "description": "A test workspace",
        "owner_user_id": "usr_abc123",
        "plan_type": "free",
        "member_limit": 50,
        "created_at": "2026-01-01T00:00:00Z"
    }
    """

    public static let memberJSON = """
    {
        "id": "mem_1",
        "container_id": "ws_1",
        "workspace_id": "ws_1",
        "team_id": "ws_1",
        "sm_user_id": "usr_abc123",
        "role": "owner",
        "full_name": "Test User",
        "email": "test@example.com",
        "avatar_url": null,
        "joined_at": "2026-01-01T00:00:00Z"
    }
    """

    public static let invitationJSON = """
    {
        "id": "inv_1",
        "container_id": "ws_1",
        "email": "invite@example.com",
        "role": "member",
        "status": "pending",
        "invited_by": "usr_abc123",
        "token": "inv_token_abc",
        "expires_at": "2026-02-01T00:00:00Z",
        "created_at": "2026-01-01T00:00:00Z"
    }
    """

    /// Wrap raw model JSON in the backend envelope: { "success": true, "data": T, "meta": {...} }
    public static func envelope(_ rawJSON: String) -> String {
        """
        {"success": true, "data": \(rawJSON), "meta": {"timestamp": "2026-01-01T00:00:00Z", "request_id": "req_test"}}
        """
    }

    public static func jsonData(_ json: String) -> Data {
        json.data(using: .utf8)!
    }

    public static func mockResponse(statusCode: Int = 200, json: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.scalemule.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, jsonData(json))
    }

    /// Convenience: envelope-wrapped mock response
    public static func envelopedResponse(statusCode: Int = 200, json: String) -> (HTTPURLResponse, Data) {
        mockResponse(statusCode: statusCode, json: envelope(json))
    }
}
