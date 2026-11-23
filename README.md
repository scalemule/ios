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
| `ScaleMuleSocial` | Posts, the app feed, likes |
| `ScaleMuleStorage` | Uploads straight to S3: sized to the connection, multipart, retried, resumable |
| `ScaleMulePhotos` | Photo upload (checked for unsafe content) and sized images |
| `ScaleMuleSafety` | Versioned consent (Terms, Privacy, licences), reporting content, blocking people, support messages |

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

## Sign in with Ledvery (Google)

Ledvery is ScaleMule's shared account service: one account and one Google
sign-in work in every ScaleMule app. The app never holds a Ledvery secret; the
auth service keeps it and turns Ledvery's one-time code into a session.

Before it works, the app needs a Ledvery client whose redirect list contains the
app's callback (for example `myapp://oauth/ledvery/callback`) and a `ledvery`
OAuth config in the auth service. The ScaleMule team provisions both.

```swift
let callback = URL(string: "myapp://oauth/ledvery/callback")!

switch await auth.signInWithLedvery(upstream: .google, callbackURL: callback) {
case .success(.signedIn(let user, _)):
    // Session stored; auth state is now .authenticated(user).
    print("Signed in as \(user.email ?? user.id)")
case .success(.linkRequired(let challenge)):
    // This email already has an account in the app. Ask for its password:
    let linked = await auth.linkLedveryAccount(challengeId: challenge.challengeId, password: password)
    // linked can also ask for .mfaCodeRequired or .emailCodeRequired; call again with the code.
case .failure(let error) where error.rawCode == AuthService.signInCancelledCode:
    break // the person closed the sheet
case .failure(let error):
    print(error.message)
}
```

The sheet shares Safari's cookies, so someone already signed in to Ledvery on
another ScaleMule site continues in one tap. `startLedverySignIn` and
`completeLedverySignIn` are available for apps that present the web page themselves.

## Photo feed (Social + Photos)

A photo feed is a Social post whose `mediaIds` hold Photos ids. Every app
gets the same feed rules from the server: everyone's `public` posts newest
first, your own posts, and posts by accounts ScaleMule marks as spam or abuse
visible only to their author.

```swift
let photos = PhotosService(app: app)
let social = SocialService(app: app)

// Post (sized to the connection, resumable; see Uploads below)
let photo = await photos.upload(jpegData, filename: "now.jpg") { progress in
    print(progress.fraction)
}
if case .success(let info) = photo {
    _ = await social.createPost(content: "Ocean Beach", mediaIds: [info.id],
                                metadata: ["width": info.width, "height": info.height])
}

// Read
if case .success(let posts) = await social.feed(page: 1, perPage: 20) {
    for post in posts {
        // Fails with rawCode PhotosService.scanPendingCode for a few seconds
        // while a new photo is checked; then returns the image bytes.
        let image = await photos.image(id: post.mediaIds?.first ?? "", width: 1080)
    }
}
```

## Uploads (Storage)

`StorageService` is the same upload pipeline as the ScaleMule web SDK, so
mobile and web uploads behave and report alike:

- **Sized to the connection.** Images are made smaller on the phone first
  (`compression: .adaptive`): 3840 px at 0.85 on a fast network, 2048 px at
  0.75 on 3G-like speeds, down to 1280 px at 0.6. The class comes from the
  interface (Wi-Fi, cellular), Low Data Mode and the upload speed this device
  actually measured on recent uploads. Capture metadata is kept; the platform
  keeps the original privately and strips the copy it serves.
- **Straight to S3.** Bytes never pass through the API: one presigned PUT for
  small files, S3 multipart above 8 MB (1 MB on a slow connection), with
  several parts in flight.
- **Retried and resumed.** Every PUT is retried (now, 1 s, 3 s); no progress
  for 45 s (90 s when slow) counts as a stall and is retried; an expired part
  link is refreshed. Finished parts are recorded on the device, so uploading
  the same bytes again, even after the app was closed, sends only the missing
  parts (server sessions last 24 hours). Cancelling the task aborts the
  upload on the server.
- **Measured.** `upload.*` events (the web SDK's names) go to ScaleMule
  analytics and logs, and failures are reported to Storage with the
  connection details.

```swift
let storage = StorageService(app: app)
let result = await storage.upload(data, options: UploadOptions(
    filename: "clip.mov", contentType: "video/quicktime", compression: .off,
    onProgress: { progress in print(progress.fraction) }))
```

`PhotosService.upload` uses this pipeline and then registers the file with
Photos (waiting out the safety scan). Pass `quality: .original` to send the
full-resolution photo unchanged.

## Auth Credential Model

ScaleMule uses a multi-credential system, not a single bearer token:

- **Session token** — always present after login
- **Access token** (optional JWT) — only when refresh tokens are enabled
- **Refresh token** (optional) — only when refresh tokens are enabled

The SDK handles credential strategy per-endpoint automatically.

## License

MIT
