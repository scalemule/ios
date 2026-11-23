import Foundation

public actor SessionManager {
    private static let credentialKey = "scalemule_credentials"
    /// The signed-in person as last confirmed by the server, so a launch
    /// without network (or with the server briefly failing) stays signed in.
    private static let userKey = "scalemule_user"

    private let keychain: KeychainStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var currentCredentials: CredentialSet?

    public init(keychain: KeychainStorage) {
        self.keychain = keychain
    }

    public var credentials: CredentialSet? {
        currentCredentials
    }

    public var isAuthenticated: Bool {
        currentCredentials != nil
    }

    public var sessionToken: String? {
        currentCredentials?.sessionToken
    }

    public var accessToken: String? {
        currentCredentials?.accessToken
    }

    public var refreshToken: String? {
        currentCredentials?.refreshToken
    }

    public var authMode: AuthMode? {
        currentCredentials?.authMode
    }

    /// Load credentials from Keychain at startup.
    public func restore() -> CredentialSet? {
        do {
            guard let data = try keychain.load(key: Self.credentialKey) else {
                return nil
            }
            let stored = try decoder.decode(StoredCredentials.self, from: data)
            let creds = stored.toCredentialSet()
            currentCredentials = creds
            return creds
        } catch {
            return nil
        }
    }

    /// Persist a new credential set to Keychain.
    public func setCredentials(_ credentials: CredentialSet) throws {
        let stored = StoredCredentials(from: credentials)
        let data = try encoder.encode(stored)
        try keychain.save(key: Self.credentialKey, data: data)
        currentCredentials = credentials
    }

    /// Update only the access token (after token refresh).
    public func updateAccessToken(_ newAccessToken: String, expiresAt: Date) throws {
        guard let creds = currentCredentials else { return }
        let updated = creds.withUpdatedAccessToken(newAccessToken, expiresAt: expiresAt)
        try setCredentials(updated)
    }

    /// Update session token after session refresh.
    public func refreshSession(_ newSessionToken: String, expiresAt: Date) throws {
        guard let creds = currentCredentials else { return }
        let updated = creds.withRefreshedSession(newSessionToken, expiresAt: expiresAt)
        try setCredentials(updated)
    }

    /// Remember who is signed in (stored next to the credentials).
    public func rememberUser(_ user: AuthUser) {
        guard currentCredentials != nil, let data = try? encoder.encode(user) else { return }
        try? keychain.save(key: Self.userKey, data: data)
    }

    /// The person last confirmed for the stored session, if any.
    public func rememberedUser() -> AuthUser? {
        guard let data = try? keychain.load(key: Self.userKey) else { return nil }
        return try? decoder.decode(AuthUser.self, from: data)
    }

    /// Clear all credentials from memory and Keychain.
    public func clear() {
        currentCredentials = nil
        try? keychain.delete(key: Self.credentialKey)
        try? keychain.delete(key: Self.userKey)
    }
}

private struct StoredCredentials: Codable {
    let sessionToken: String
    let accessToken: String?
    let refreshToken: String?
    let sessionExpiresAt: TimeInterval
    let absoluteExpiresAt: TimeInterval?
    let accessTokenExpiresAt: TimeInterval?

    init(from creds: CredentialSet) {
        sessionToken = creds.sessionToken
        accessToken = creds.accessToken
        refreshToken = creds.refreshToken
        sessionExpiresAt = creds.sessionExpiresAt.timeIntervalSince1970
        absoluteExpiresAt = creds.absoluteExpiresAt?.timeIntervalSince1970
        accessTokenExpiresAt = creds.accessTokenExpiresAt?.timeIntervalSince1970
    }

    func toCredentialSet() -> CredentialSet {
        CredentialSet(
            sessionToken: sessionToken,
            accessToken: accessToken,
            refreshToken: refreshToken,
            sessionExpiresAt: Date(timeIntervalSince1970: sessionExpiresAt),
            absoluteExpiresAt: absoluteExpiresAt.map { Date(timeIntervalSince1970: $0) },
            accessTokenExpiresAt: accessTokenExpiresAt.map { Date(timeIntervalSince1970: $0) }
        )
    }
}
