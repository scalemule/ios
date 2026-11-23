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
| `ScaleMuleSocial` | Posts, the app feed, likes; post locations and search near / at a venue |
| `ScaleMuleStorage` | Uploads straight to S3: sized to the connection, multipart, retried, resumable |
| `ScaleMulePhotos` | Photo upload (checked for unsafe content) and sized images |
| `ScaleMuleVideos` | Short videos: resumable upload, adaptive streaming (HLS) playback links |
| `ScaleMuleCapture` | Camera for capture screens: photos, multi-clip video takes, zoom/focus/flash, preview (iOS 17+) |
| `ScaleMuleMediaEditing` | Photo looks and adjustments; video composer (join clips, trim, look, mute, export, poster); watermark and save to Photos |
| `ScaleMuleMediaQueue` | Durable background posting: survives app restarts, resumable uploads, originals on Wi-Fi; your app publishes |
| `ScaleMuleLocation` | Location for posts and "around me": permission and real fixes, venue/city/nearest-city/exact choices (Apple Maps), a Nearby feed model |
| `ScaleMuleFeed` | Full-screen paging feed with cell reuse (`FeedPager`), reports the posts coming next for preloading |
| `ScaleMuleSafety` | Versioned consent (Terms, Privacy, licences), reporting content, blocking people, support messages |
| `ScaleMuleProfiles` | Add, change or remove your profile photo; other people's names and photos, cached |
| `ScaleMuleMediaPosts` | A photo and video feed kit: `MediaPost`, `MediaPostPublisher`, `SocialFeedModel` (everyone / mine / nearby, saved first page, new-post polling, likes, hiding), `RemotePhotoView`, `RemoteVideoView`, `ProfileAvatarView` |

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

## Profile photos (Profiles)

`ProfilePhotoService` adds, changes or removes the signed-in person's profile
photo. The picture goes through Photos like any other (checked for unsafe
content before anyone sees it) but is stored as a public photo, so the
profile's `avatar_url` is a stable, unsigned link on ScaleMule's public CDN: a
256 px square JPEG that any screen, page or person can show without a key, and
that never expires.

```swift
let profilePhotos = ProfilePhotoService(app: app)

// From the Photos picker or the camera
switch await profilePhotos.setProfilePhoto(uiImage) { progress in print(progress.fraction) } {
case .success(let user):
    print(user.avatarURL!)  // https://cdn-public.scalemule.com/{app}/anonymous/photos/{photo}/w256_h256_cover_q85_jpeg.jpg (or .jpeg)
case .failure(let error):
    show(error.userFacingMessage)
}

_ = await profilePhotos.removeProfilePhoto()   // avatar_url becomes "", photo deleted
```

What `setProfilePhoto` does: makes the picture upright, at most 1024 px, with
no metadata (no GPS, camera or time); uploads it with Storage visibility
`anonymous_visible` and registers it with Photos; takes the link Photos records
for the 256 px square (`GET /v1/photos/public/{id}/manifest?rendition=w256_h256_cover_q85_jpeg`,
asking the public transform to make it if it is not there yet); sets
`avatar_url` with `PATCH /v1/auth/profile`, which also updates the auth state;
then deletes the previous profile photo it made. `setProfilePhoto(_ data:)`
takes encoded bytes (JPEG, HEIC, PNG) and works on macOS too.
`AuthUser.avatarURL` is the photo link or nil (Auth keeps `""` for a removed
photo; only HTTPS links are returned).

The lower-level pieces are on `PhotosService`: `uploadPublic` (a public photo),
`publicRendition` and `publicImageURL(photoId:width:height:fit:format:quality:)`
(the unsigned CDN link of one size).

Other people's names and photos come from `PublicProfiles`, an actor that
caches `GET /v1/auth/users/{id}` (a signed-in caller sees only the contact-free
view of anyone else: no email or phone):

```swift
let people = PublicProfiles(app: app)              // keep one for the app
if let author = await people.profile(post.userId) {
    print(author.name ?? "", author.avatarURL as Any)
}
```

Lookups are kept for 10 minutes, a person who could not be found for 1 minute,
and concurrent lookups of one person share one request (`ttl`, `missTTL` and
`capacity` can be set). `remember`, `forget` and `removeAll` update the cache.

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

To keep originals without making people wait on mobile data, post
`.original` when `photos.originalIsCheapToSend()` (Wi-Fi, not Low Data
Mode), and otherwise post `.adaptive` now and later, on Wi-Fi, call
`photos.attachOriginal(photoId:_:filename:)`. The original becomes the
photo's source (every size is made from it); the server accepts only the
uploader and the same picture, at least as large.

## Posting photos and videos (Instagram/TikTok style)

The media modules give any ScaleMule app the full posting flow; the app
draws its own screens and decides what a post is.

```swift
// Capture: photos, and video takes of several clips (hold, release, hold again).
let camera = CaptureController(maxVideoSeconds: 60)
CapturePreview(controller: camera)              // SwiftUI; tap focuses, pinch zooms
try await camera.capturePhoto()                 // -> camera.capturedImage
camera.startClip(); camera.stopClip()           // per press; camera.clips, recordedSeconds
let clips = camera.finishTake()                 // or deleteLastClip(), discardTake()

// Edit: the same looks for photos and every video frame.
var edit = VideoEdit(clips: clips, trimStart: 0.5, trimEnd: 12, look: .vivid, muted: false)
let preview = try await VideoComposer.preview(for: edit)        // looping.load(preview.item, timeRange: preview.timeRange)

// Post in the background; the queue keeps it on the phone until published.
let queue = MediaUploadQueue(photos: photos, videos: videos) { upload in
    // Your app's post, for example a Social post with upload.mediaId.
    let result = await social.createPost(content: upload.attributes["caption"] ?? "", mediaIds: [upload.mediaId])
    return result.isSuccess ? .success(()) : .failure(.init(result.error?.userFacingMessage ?? "Could not post"))
}
queue.restore()                                  // once signed in: carries on after a relaunch
queue.post(video: edit, attributes: ["caption": "Ocean Beach"])
queue.post(photo: image, attributes: [:])        // originals follow on Wi-Fi automatically

// Show: photos (cached on disk, waits out the safety check) and videos.
let image = await photos.loadImage(id: photoId, width: 1080, cache: .shared)
let model = VideoPlaybackModel(videoId: videoId, videos: videos)   // poster, waits for conversion
PlayerLayerView(player: model.player, gravity: .resizeAspectFill)
model.play(); model.togglePause(); model.isMuted = true
```

## Location: privacy and "around me" (Social + Location)

People pick per post how much of where they are to share; nobody's spot is
exposed and "Nearby" stays fast for any number of posts. Platform contract:
scalemule-repos `docs/LOCATION-PRIVACY.md`.

```swift
// Info.plist: NSLocationWhenInUseUsageDescription
let access = LocationAccess.shared
access.requestPermission()

// Share screen: the ways this fix can be shared (venue, city or nearest
// city, exact spot, none). Only the chosen public point leaves the phone.
var settings = LocationSettings.standard
if case .success(let fromApp) = await social.locationSettings() { settings = fromApp }
if let here = await access.freshLocation() {
    let choices = await PlaceResolver.shared.choices(for: here)
    let kind = choices.defaultKind(settings)          // .city unless the app says otherwise
    let shared = choices.location(for: kind)          // nil for .none
    queue.post(photo: image, attributes: [...], capture: CaptureLocation(here))
    // ...and the app's publish step passes `shared` to
    // social.createPost(..., location: shared)
}

// "Around me": only from a real, fresh fix; widens 5 → 25 → 160 km.
let nearby = NearbyFeed(social: social)
await nearby.load()                                   // or .place(id:name:) for a venue
// nearby.problem == .notHere → offer "Explore anywhere"
```

- `capture` (where and when it was taken) goes into the uploaded file only.
  ScaleMule Photos and Video keep it privately with the original and serve
  copies without it. Do not strip it on the phone, and never put
  coordinates in post `metadata` (Social removes them).
- Social snaps every shared point to its precision (city about 2 km, area
  about 11 km) and searches only public posts by those points.
- Searching follows where the person is: a jump nobody could make is refused
  (`ApiError.isLocationNotHere`) unless the app's server granted "Explore
  anywhere" (`PUT /v1/social/location/explorers/{user_id}`, for example after
  an App Store purchase). Simulated locations are never used.

## Full-screen feeds that scroll smoothly (Feed + Photos + Videos)

`FeedPager` is a TikTok/Reels-style vertical feed built on
`UICollectionView`: only the cells near the screen exist and are reused,
so memory stays flat however far people scroll (500 posts scroll with at
most 4 post views alive). Preload what comes next so every swipe lands on
a ready picture or a video that starts at once:

```swift
let prefetcher = PhotoPrefetcher(photos: photos)        // pictures, 3 at a time
FeedPager(items: posts, activeID: $activeId, lookahead: 4, loadMoreDistance: 8,
          onUpcoming: { next in
              prefetcher.prefetch(next.filter(\.isPhoto).map(\.mediaId), width: screenWidth)
              VideoPreloader.shared.preload(next.filter(\.isVideo).map(\.mediaId), videos: videos)
          },
          onNearEnd: { Task { await loadMore() } },
          onRefresh: { await reload() }) { post, isActive in
    PostView(post: post, isActive: isActive)              // play only while isActive
        .environmentObject(app)                           // cells live in UIKit
}
```

- `PhotoImageCache` keeps decoded pictures within a byte budget, decodes
  them off the main thread and drops them on a memory warning (disk copies
  stay).
- `VideoPreloader` fetches about the first second of each of the next
  four videos (TikTok style) in muted, paused players that `VideoPlaybackModel` takes over; they are released on a
  memory warning.

## Building a photo and video feed app

The whole stack of a TikTok/Instagram-style app (Firehosy runs on exactly
this). Your app draws its own screens, buttons and colours; the SDK does
capture, editing, posting, location, the feed and the media views.

```swift
import ScaleMule

let app = ScaleMuleApp(config: config)
let social = SocialService(app: app), photos = PhotosService(app: app), videos = VideosService(app: app)

// 1. Capture and edit (ScaleMuleCapture, ScaleMuleMediaEditing).
let camera = CaptureController(maxVideoSeconds: 60)
CapturePreview(controller: camera)
var edit = VideoEdit(clips: camera.finishTake(), look: .vivid)

// 2. Where to say it was (ScaleMuleLocation): only the chosen public point leaves the phone.
let here = await LocationAccess.shared.freshLocation()
let choices = await PlaceResolver.shared.choices(for: here!)
let shared = choices.location(for: choices.defaultKind(settings))       // venue, city, spot or nil

// 3. Post in the background (ScaleMuleMediaQueue) and publish a MediaPost.
let publisher = MediaPostPublisher(social: social, tags: ["myapp-world"])
let queue = MediaUploadQueue(photos: photos, videos: videos) { upload in
    switch await publisher.publish(upload, authorName: MediaPostPublisher.authorName(for: user)) {
    case .success(let post): feed.insertOwnPost(post); return .success(())
    case .failure(let error): return .failure(.init(error.userFacingMessage))
    }
}
queue.restore()
queue.post(video: edit, attributes: MediaPostAttributes.make(caption: "Ocean Beach", location: shared),
           capture: CaptureLocation(here!))                             // the real spot stays private

// 4. The feed model: everyone's posts, yours, or nearby.
@StateObject var feed = SocialFeedModel()                               // pageSize 20, polls every 15 s
feed.attach(social: social, photos: photos, videos: videos, currentUserId: user.id) // opens on the saved first page
await feed.loadFeed()
feed.filter = .nearby                                                   // or .mine / .everyone
feed.startPolling()                                                     // feed.newItems → feed.showNewItems()
feed.setBlockedAuthors(blockedIds); feed.hideReported(post)
await feed.toggleLike(post); feed.likeCount(post); feed.isLiked(post)
await feed.block(post) { await blocks.block(post.authorId, by: user.id) }
await feed.deleteOwnPost(post)

// 5. Draw it: FeedPager (cells reused, next posts preloaded) and the media views.
FeedPager(items: feed.items, activeID: $activeId,
          onUpcoming: { next in
              prefetcher.prefetch(next.filter(\.isPhoto).map { (id: $0.mediaId, width: RemotePhotoView.requestWidth(wide: $0.isLandscape)) })
              VideoPreloader.shared.preload(next.filter(\.isVideo).map(\.mediaId), videos: videos)
          },
          onNearEnd: { Task { await feed.loadMore() } },
          onRefresh: { await feed.refresh() }) { post, isActive in
    ZStack {
        if post.isVideo {
            RemoteVideoView(post: post, size: screen, isActive: isActive, videos: videos, topInset: safeTop)
        } else {
            RemotePhotoView(photoId: post.mediaId, size: screen, wide: post.isLandscape, photos: photos,
                            wideStyle: .pan(hint: "Swipe sideways")) { image in open(image) }
        }
        // Your overlay: post.authorName, post.caption, post.place, post.timeAgo(),
        // post.distanceString(from: here), feed.likeCount(post) ...
        ProfileAvatarView(url: avatarURL, name: post.authorName, background: .mint, foreground: .black)
    }
}

// 6. Profiles (ScaleMuleProfiles): authors' names and photos, cached.
let people = PublicProfiles(app: app)
let avatarURL = post.isMine ? user.avatarURL : await people.profile(post.authorId)?.avatarURL
```

- `MediaPost` reads any Social post whose first media id is a photo or a
  video, with the metadata keys in `MediaPost.Keys` (`kind`, `author_name`,
  `place`, `width`, `height`, `caption`, `duration`). Posts from before post
  locations (only `place` in metadata) still read; coordinates in metadata
  are never used. It is `Codable` for saved copies.
- `MediaPostPublisher` never puts coordinates in metadata: the location goes
  in the post's `location` (Social snaps it to its precision) and its label in
  `place` for older readers.
- `SocialFeedModel`: a load replaced by a newer one (another filter) never
  overwrites it; likes start from the server's `liked_by_me` and a 409 counts
  as already liked; `showFixed(_:)` shows sample posts for previews and UI
  tests. Its "Nearby" errors are `nearbyProblemMessage`.
- `RemotePhotoView` starts from the memory cache (no spinner for a preloaded
  photo), shows "Checking photo…" during the safety check and "Tap to try
  again" after a failure; it fetches 1080 (upright) or 1600 (wide). Its
  `loader` replaces the network for previews and UI tests.
- `RemoteVideoView` plays while `isActive`, pauses on tap and remembers the
  mute button (`muteKey`). Both views are neutral (white on black); text is
  in `labels`. `ProfileAvatarView` takes your colours and font.
- `deleteOwnPost` on a video post deletes the video first with
  `VideosService.delete(id:)` (Video removes every stored copy: streaming
  copies, poster, preview, the Storage original, statistics, CDN copies;
  this phone's file, playback link, buffered player and poster go too), then
  the post. A video already gone (404) counts as deleted; any other failure
  keeps the post and sets `error`, so deleting again finishes the job. A photo
  post deletes the post, then the photo.

## Usage analytics for photos and videos

Every app built on the SDK reports how its media is used, with no extra code:

- **Video** (`VideoPlaybackModel`, or `PlaybackAnalytics` for a custom
  player): `play` at the first frame (time to first frame, starting
  quality), `heartbeat` every 10 s, `buffer` after each stall, `complete` at
  each loop, `pause` on pause or leaving, `error`. Running totals: watched
  seconds, watch-through, rebuffer ratio, quality switches, dropped frames,
  bandwidth and segment load time, connection type. They appear in the
  ScaleMule dashboard's Video analytics (views, completions, watch time,
  quality of experience). Turn off with `PlaybackAnalytics.isEnabled = false`.
- **Posts and photos** (`SocialFeedModel`): call `setActivePost(id)` from
  `FeedPager`'s active post. A post seen for a second counts one view in
  ScaleMule Social (total and unique viewers per post); leaving it records
  `feed.post_view` with how long it was on screen. `trackAction("open" |
  "share" | "save", post)` records actions; `flushAnalytics()` when the app
  goes to the background.
- `AnalyticsEvents` sends any other product event to ScaleMule Analytics.

## Auth Credential Model

ScaleMule uses a multi-credential system, not a single bearer token:

- **Session token** — always present after login
- **Access token** (optional JWT) — only when refresh tokens are enabled
- **Refresh token** (optional) — only when refresh tokens are enabled

The SDK handles credential strategy per-endpoint automatically.

## License

MIT
