import Foundation

public final class ScaleMuleApp: Sendable {
    public let config: Configuration
    public let client: HTTPClient
    public let sessionManager: SessionManager
    public let authState: AuthStateManager
    public let networkMonitor: NetworkMonitor
    private let workspaceContext: WorkspaceContext

    public init(config: Configuration) {
        self.config = config
        let keychain = KeychainStorage(service: "com.scalemule.sdk.\(config.apiKey.prefix(8))")
        let sessionManager = SessionManager(keychain: keychain)
        let workspaceContext = WorkspaceContext()
        self.sessionManager = sessionManager
        self.workspaceContext = workspaceContext
        self.client = HTTPClient(
            config: config,
            sessionManager: sessionManager,
            workspaceContext: workspaceContext
        )
        self.authState = AuthStateManager()
        self.networkMonitor = NetworkMonitor()
    }

    /// For testing: inject a custom URLSession.
    public init(config: Configuration, urlSession: URLSession) {
        self.config = config
        let keychain = KeychainStorage(service: "com.scalemule.sdk.test")
        let sessionManager = SessionManager(keychain: keychain)
        let workspaceContext = WorkspaceContext()
        self.sessionManager = sessionManager
        self.workspaceContext = workspaceContext
        self.client = HTTPClient(
            config: config,
            sessionManager: sessionManager,
            workspaceContext: workspaceContext,
            urlSession: urlSession
        )
        self.authState = AuthStateManager()
        self.networkMonitor = NetworkMonitor()
    }

    /// Load session from Keychain and start network monitor.
    public func initialize() async {
        await authState.transition(to: .loading)
        await networkMonitor.start()

        if let creds = await sessionManager.restore() {
            // Validate session is not expired
            if creds.sessionExpiresAt > Date() {
                // Fetch user profile to confirm session is valid
                let options = RequestOptions(
                    method: .get,
                    path: "/v1/auth/me",
                    credential: .sessionToken
                )
                let result: ApiResponse<AuthUser> = await client.request(options)
                switch result {
                case .success(let user):
                    await authState.transition(to: .authenticated(user))
                case .failure:
                    await sessionManager.clear()
                    await authState.transition(to: .unauthenticated)
                }
            } else {
                await sessionManager.clear()
                await authState.transition(to: .unauthenticated)
            }
        } else {
            await authState.transition(to: .unauthenticated)
        }
    }

    public func setCredentials(_ credentials: CredentialSet) async {
        try? await sessionManager.setCredentials(credentials)
    }

    public func clearSession() async {
        await sessionManager.clear()
        await authState.transition(to: .unauthenticated)
    }

    public var isAuthenticated: Bool {
        get async {
            await sessionManager.isAuthenticated
        }
    }

    public func setWorkspaceContext(_ workspaceId: String?) async {
        await workspaceContext.set(workspaceId)
    }

    public func authStateStream() async -> AsyncStream<AuthState> {
        await authState.stream()
    }
}
