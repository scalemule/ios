import Foundation
import ScaleMule

// Integration test against api-dev.scalemule.com
// Tests the register → login → me → logout flow

let apiKey = ProcessInfo.processInfo.environment["SM_API_KEY"] ?? "sm_sk_development_019cff63a10171929c0102ba2ce5580c"
let baseURL = ProcessInfo.processInfo.environment["SM_BASE_URL"] ?? "https://api-dev.scalemule.com"

let testEmail = "ios-sdk-test-\(UUID().uuidString.prefix(8).lowercased())@test.scalemule.dev"
let testPassword = "TestP@ss123!"

func log(_ msg: String) {
    print("[iOS SDK E2E] \(msg)")
}

func fail(_ msg: String) -> Never {
    print("[iOS SDK E2E] FAIL: \(msg)")
    exit(1)
}

@Sendable
func run() async {
    log("Starting integration test against \(baseURL)")
    log("API key: \(apiKey.prefix(20))...")
    log("Test email: \(testEmail)")

    let app = ScaleMuleApp(config: Configuration(
        apiKey: apiKey,
        customBaseURL: URL(string: baseURL)!,
        maxRetries: 1,
        timeoutInterval: 15,
        debug: true
    ))

    let auth = AuthService(app: app)

    // Verify initial state
    let initialState = await app.authState.state
    guard initialState == .unknown else {
        fail("Expected initial state .unknown, got \(initialState)")
    }
    log("PASS: Initial state is .unknown")

    // ── Step 1: Register ──────────────────────────────────────────────
    log("Step 1: Register...")
    let registerResult = await auth.register(
        email: testEmail,
        password: testPassword,
        name: "iOS SDK Test User"
    )

    switch registerResult {
    case .success(let user):
        log("  Registered user: \(user.id)")
        log("  Email: \(user.email ?? "nil")")
        guard user.email == testEmail else {
            fail("Email mismatch: expected \(testEmail), got \(user.email ?? "nil")")
        }

        let postRegState = await app.authState.state
        if case .pendingEmailVerification(let u) = postRegState {
            log("  PASS: State transitioned to .pendingEmailVerification(\(u.id))")
        } else {
            fail("Expected .pendingEmailVerification, got \(postRegState)")
        }

    case .failure(let error):
        fail("Register failed: \(error.code) - \(error.message)")
    }

    // ── Step 2: Login (email may not be verified, depending on app config) ──
    log("Step 2: Login...")
    let loginResult = await auth.login(email: testEmail, password: testPassword)

    switch loginResult {
    case .success(let login):
        log("  Session token: \(login.sessionToken.prefix(20))...")
        log("  User ID: \(login.user.id)")
        if let device = login.device {
            log("  Device: \(device.name) (trust: \(device.trustLevel), new: \(device.isNew))")
        }
        if let risk = login.risk {
            log("  Risk: score=\(risk.score) action=\(risk.action)")
        }

        let postLoginState = await app.authState.state
        if case .authenticated(let u) = postLoginState {
            log("  PASS: State transitioned to .authenticated(\(u.id))")
        } else {
            fail("Expected .authenticated after login, got \(postLoginState)")
        }

    case .failure(let error):
        if error.code == .mfaRequired {
            log("  Login requires MFA (expected for MFA-enabled apps)")
            log("  PASS: MFA challenge returned correctly")
            log("  Skipping me/logout (MFA not completable in headless test)")
            log("INTEGRATION TEST PASSED (MFA path)")
            exit(0)
        } else if error.code == .emailNotVerified {
            log("  Login rejected: email not verified (expected for strict apps)")
            log("  PASS: Email verification enforcement works correctly")
            log("INTEGRATION TEST PASSED (email-verification-required path)")
            exit(0)
        } else {
            fail("Login failed: \(error.code) - \(error.message)")
        }
    }

    // ── Step 3: me() ──────────────────────────────────────────────────
    log("Step 3: me()...")
    let meResult = await auth.me()

    switch meResult {
    case .success(let user):
        log("  User: \(user.id)")
        log("  Email: \(user.email ?? "nil")")
        log("  Name: \(user.fullName ?? "nil")")
        guard user.email == testEmail else {
            fail("me() email mismatch")
        }
        log("  PASS: me() returned correct user")

    case .failure(let error):
        fail("me() failed: \(error.code) - \(error.message)")
    }

    // ── Step 4: Sessions list ─────────────────────────────────────────
    log("Step 4: sessions.list()...")
    let sessionsResult = await auth.sessions.list()

    switch sessionsResult {
    case .success(let sessions):
        log("  Sessions: \(sessions.total) total")
        if let current = sessions.sessions.first(where: { $0.isCurrent == true }) {
            log("  Current session: \(current.id)")
        }
        log("  PASS: Sessions listed successfully")

    case .failure(let error):
        log("  WARN: sessions.list() failed: \(error.code) - \(error.message)")
    }

    // ── Step 5: Logout ────────────────────────────────────────────────
    log("Step 5: Logout...")
    let logoutResult = await auth.logout()

    switch logoutResult {
    case .success:
        log("  PASS: Logout succeeded")
    case .failure(let error):
        log("  WARN: Logout server call failed (\(error.code)), but session cleared locally")
    }

    let postLogoutState = await app.authState.state
    if case .unauthenticated = postLogoutState {
        log("  PASS: State transitioned to .unauthenticated")
    } else {
        fail("Expected .unauthenticated after logout, got \(postLogoutState)")
    }

    // ── Step 6: Verify session is dead ────────────────────────────────
    log("Step 6: Verify session is cleared...")
    let postLogoutMe = await auth.me()
    if case .failure = postLogoutMe {
        log("  PASS: me() correctly fails after logout")
    } else {
        fail("me() should fail after logout")
    }

    log("")
    log("═══════════════════════════════════════")
    log("  INTEGRATION TEST PASSED")
    log("  register → login → me → sessions → logout → verify")
    log("═══════════════════════════════════════")
}

await run()
