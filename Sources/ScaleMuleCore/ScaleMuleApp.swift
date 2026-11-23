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
    ///
    /// The server decides whether a session is still good: its expiry moves
    /// forward while the app is used, so the expiry saved at sign-in is not
    /// checked here (only the absolute one is). The stored session is cleared
    /// only when the server rejects it; offline, a timeout or a server error
    /// keeps the person signed in as last confirmed and checks again later.
    public func initialize() async {
        await authState.transition(to: .loading)
        await networkMonitor.start()

        guard let creds = await sessionManager.restore() else {
            await authState.transition(to: .unauthenticated)
            return
        }
        if let absolute = creds.absoluteExpiresAt, absolute <= Date() {
            await clearSession()
            return
        }
        switch await confirmSession() {
        case .confirmed(let user):
            await authState.transition(to: .authenticated(user))
        case .rejected:
            await clearSession()
        case .unreachable:
            if let user = await sessionManager.rememberedUser() {
                await authState.transition(to: .authenticated(user))
            } else {
                // Signed in with an older SDK that kept no profile: show
                // sign-in for now, keep the session, and recover when the
                // server answers.
                await authState.transition(to: .unauthenticated)
            }
            Task { await self.recheckSession(token: creds.sessionToken) }
        }
    }

    enum SessionCheck: Sendable {
        case confirmed(AuthUser)
        case rejected
        case unreachable
    }

    /// Asks the server who the stored session belongs to.
    func confirmSession() async -> SessionCheck {
        let options = RequestOptions(
            method: .get,
            path: "/v1/auth/me",
            credential: .sessionToken
        )
        let result: ApiResponse<AuthUser> = await client.request(options)
        switch result {
        case .success(let user):
            await sessionManager.rememberUser(user)
            return .confirmed(user)
        case .failure(let error):
            return Self.isSessionRejected(error) ? .rejected : .unreachable
        }
    }

    /// Only a definite answer about the session ends it: 401, or a 403 that
    /// names the session. Network errors, timeouts, 429 and 5xx do not.
    static func isSessionRejected(_ error: ApiError) -> Bool {
        if error.statusCode == 401 || error.code == .unauthorized || error.code == .sessionExpired { return true }
        if error.statusCode == 403, let raw = error.rawCode?.uppercased(), raw.contains("SESSION") { return true }
        return false
    }

    /// After an unreachable launch: check again with growing pauses until the
    /// server answers, as long as the same session is stored.
    func recheckSession(token: String, delays: [UInt64] = [2, 5, 15, 30, 60, 120, 300]) async {
        var attempt = 0
        while await sessionManager.sessionToken == token {
            let delay = delays[min(attempt, delays.count - 1)]
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard await sessionManager.sessionToken == token else { return }
            switch await confirmSession() {
            case .confirmed(let user):
                await authState.transition(to: .authenticated(user))
                return
            case .rejected:
                await clearSession()
                return
            case .unreachable:
                attempt += 1
            }
        }
    }

    /// Persist credentials and transition auth state to authenticated.
    public func setCredentials(_ credentials: CredentialSet, user: AuthUser) async {
        try? await sessionManager.setCredentials(credentials)
        await sessionManager.rememberUser(user)
        await authState.transition(to: .authenticated(user))
    }

    /// Clear all credentials and transition auth state to unauthenticated.
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
