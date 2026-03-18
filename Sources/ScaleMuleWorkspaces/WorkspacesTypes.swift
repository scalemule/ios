import Foundation
import ScaleMuleCore

// MARK: - Workspace (Container)

public struct ContainerResponse: Sendable, Decodable {
    public let id: String
    public let smApplicationId: String?
    public let kind: String?
    public let name: String
    public let description: String?
    public let ownerUserId: String?
    public let planType: String?
    public let memberLimit: Int?
    public let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case smApplicationId = "sm_application_id"
        case kind
        case name
        case description
        case ownerUserId = "owner_user_id"
        case planType = "plan_type"
        case memberLimit = "member_limit"
        case createdAt = "created_at"
    }
}

// MARK: - Member

public struct MemberResponse: Sendable, Decodable {
    public let id: String?
    public let containerId: String?
    public let smUserId: String
    public let role: String?
    public let fullName: String?
    public let email: String?
    public let avatarUrl: String?
    public let joinedAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case containerId = "container_id"
        case smUserId = "sm_user_id"
        case role
        case fullName = "full_name"
        case email
        case avatarUrl = "avatar_url"
        case joinedAt = "joined_at"
    }
}

// MARK: - Invitation

public struct InvitationResponse: Sendable, Decodable {
    public let id: String
    public let containerId: String?
    public let email: String
    public let role: String?
    public let status: String?
    public let invitedBy: String?
    public let token: String?
    public let expiresAt: String?
    public let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case containerId = "container_id"
        case email
        case role
        case status
        case invitedBy = "invited_by"
        case token
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }
}

// MARK: - SSO Configuration

public struct SsoConfigurationResponse: Sendable, Decodable {
    public let id: String?
    public let containerId: String?
    public let providerType: String?
    public let providerName: String?
    public let samlIdpEntityId: String?
    public let samlIdpSsoUrl: String?
    public let oauthClientId: String?
    public let oauthAuthorizeUrl: String?
    public let oauthTokenUrl: String?
    public let oauthUserinfoUrl: String?
    public let allowedDomains: [String]?
    public let attributeMapping: AnyCodable?
    public let isEnabled: Bool?
    public let isEnforced: Bool?
    public let jitProvisioningEnabled: Bool?
    public let defaultRole: String?
    public let metadata: AnyCodable?
    public let createdAt: String?
    public let updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case containerId = "container_id"
        case providerType = "provider_type"
        case providerName = "provider_name"
        case samlIdpEntityId = "saml_idp_entity_id"
        case samlIdpSsoUrl = "saml_idp_sso_url"
        case oauthClientId = "oauth_client_id"
        case oauthAuthorizeUrl = "oauth_authorize_url"
        case oauthTokenUrl = "oauth_token_url"
        case oauthUserinfoUrl = "oauth_userinfo_url"
        case allowedDomains = "allowed_domains"
        case attributeMapping = "attribute_mapping"
        case isEnabled = "is_enabled"
        case isEnforced = "is_enforced"
        case jitProvisioningEnabled = "jit_provisioning_enabled"
        case defaultRole = "default_role"
        case metadata
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - SSO Configure Request

public struct ConfigureSsoRequest: @unchecked Sendable {
    public let providerType: String
    public let providerName: String?
    public let samlIdpEntityId: String?
    public let samlIdpSsoUrl: String?
    public let samlIdpCertificate: String?
    public let oauthClientId: String?
    public let oauthClientSecret: String?
    public let oauthAuthorizeUrl: String?
    public let oauthTokenUrl: String?
    public let oauthUserinfoUrl: String?
    public let allowedDomains: [String]?
    public let attributeMapping: [String: Any]?
    public let isEnabled: Bool?
    public let isEnforced: Bool?
    public let jitProvisioningEnabled: Bool?
    public let defaultRole: String?
    public let metadata: [String: Any]?

    public init(
        providerType: String,
        providerName: String? = nil,
        samlIdpEntityId: String? = nil,
        samlIdpSsoUrl: String? = nil,
        samlIdpCertificate: String? = nil,
        oauthClientId: String? = nil,
        oauthClientSecret: String? = nil,
        oauthAuthorizeUrl: String? = nil,
        oauthTokenUrl: String? = nil,
        oauthUserinfoUrl: String? = nil,
        allowedDomains: [String]? = nil,
        attributeMapping: [String: Any]? = nil,
        isEnabled: Bool? = nil,
        isEnforced: Bool? = nil,
        jitProvisioningEnabled: Bool? = nil,
        defaultRole: String? = nil,
        metadata: [String: Any]? = nil
    ) {
        self.providerType = providerType
        self.providerName = providerName
        self.samlIdpEntityId = samlIdpEntityId
        self.samlIdpSsoUrl = samlIdpSsoUrl
        self.samlIdpCertificate = samlIdpCertificate
        self.oauthClientId = oauthClientId
        self.oauthClientSecret = oauthClientSecret
        self.oauthAuthorizeUrl = oauthAuthorizeUrl
        self.oauthTokenUrl = oauthTokenUrl
        self.oauthUserinfoUrl = oauthUserinfoUrl
        self.allowedDomains = allowedDomains
        self.attributeMapping = attributeMapping
        self.isEnabled = isEnabled
        self.isEnforced = isEnforced
        self.jitProvisioningEnabled = jitProvisioningEnabled
        self.defaultRole = defaultRole
        self.metadata = metadata
    }

    var toDictionary: [String: Any] {
        var dict: [String: Any] = ["provider_type": providerType]
        if let providerName { dict["provider_name"] = providerName }
        if let samlIdpEntityId { dict["saml_idp_entity_id"] = samlIdpEntityId }
        if let samlIdpSsoUrl { dict["saml_idp_sso_url"] = samlIdpSsoUrl }
        if let samlIdpCertificate { dict["saml_idp_certificate"] = samlIdpCertificate }
        if let oauthClientId { dict["oauth_client_id"] = oauthClientId }
        if let oauthClientSecret { dict["oauth_client_secret"] = oauthClientSecret }
        if let oauthAuthorizeUrl { dict["oauth_authorize_url"] = oauthAuthorizeUrl }
        if let oauthTokenUrl { dict["oauth_token_url"] = oauthTokenUrl }
        if let oauthUserinfoUrl { dict["oauth_userinfo_url"] = oauthUserinfoUrl }
        if let allowedDomains { dict["allowed_domains"] = allowedDomains }
        if let attributeMapping { dict["attribute_mapping"] = attributeMapping }
        if let isEnabled { dict["is_enabled"] = isEnabled }
        if let isEnforced { dict["is_enforced"] = isEnforced }
        if let jitProvisioningEnabled { dict["jit_provisioning_enabled"] = jitProvisioningEnabled }
        if let defaultRole { dict["default_role"] = defaultRole }
        if let metadata { dict["metadata"] = metadata }
        return dict
    }
}
