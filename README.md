# ScaleMule iOS SDK

Swift Package for integrating ScaleMule into iOS and macOS applications.

## Requirements

- iOS 16+ / macOS 13+
- Swift 5.9+
- Xcode 15+

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/scalemule/ios.git", from: "0.0.1"),
]
```

Or in Xcode: File > Add Package Dependencies > enter `https://github.com/scalemule/ios`.

## Modules

| Module | Description |
|--------|-------------|
| `ScaleMule` | Umbrella — imports all modules |
| `ScaleMuleCore` | HTTP client, auth state, credentials, configuration |
| `ScaleMuleAuth` | Authentication (register, login, MFA, OAuth, sessions, devices) |
| `ScaleMulePermissions` | Roles, permission checks, policies |
| `ScaleMuleWorkspaces` | Workspace CRUD, members, invitations, SSO |

## Quick Start

```swift
import ScaleMule

let app = ScaleMuleApp(config: Configuration(
    apiKey: "pk_live_your_api_key",
    environment: .production
))

// Initialize — loads session from Keychain
await app.initialize()

// Auth
let auth = AuthService(client: app.client)

let result = await auth.login(email: "user@example.com", password: "password")
switch result {
case .success(let login):
    await app.setCredentials(login.toCredentialSet())
case .failure(let error):
    if error.code == .mfaRequired {
        // Handle MFA challenge
    }
}

// Observe auth state
for await state in await app.authStateStream() {
    switch state {
    case .authenticated(let user):
        print("Logged in as \(user.email ?? "")")
    case .mfaRequired(let challenge):
        // Show MFA input
    case .unauthenticated:
        // Show login
    default:
        break
    }
}
```

## Auth Credential Model

ScaleMule uses a multi-credential system, not a single bearer token:

- **Session token** — always present after login
- **Access token** (optional JWT) — only when refresh tokens are enabled
- **Refresh token** (optional) — only when refresh tokens are enabled

The SDK handles credential strategy per-endpoint automatically.

## License

MIT
