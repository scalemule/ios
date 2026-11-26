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
| `ScaleMuleCommerce` | Digital gifts, inventory, StoreKit credit packs, durable purchase/gift recovery and shared SwiftUI views |
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

Call `startSession()` when the camera screen appears and `stopSession()` when
it disappears. The controller pauses in the background, resumes only while
that screen still requests the camera, and attempts one recovery after a media
services reset. Show `interruption?.message` for temporary iOS restrictions,
and offer `startSession()` as a manual retry for `error`.
`CapturePreview` updates `isPreviewScreenCaptured` using the view's scene traits.
Use it for a screen-sharing hint, not to disable capture: it also includes
screen recordings that can still show a working camera. iPhone mirroring can
make iOS suppress camera frames; the SDK does not bypass that restriction.

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
so offscreen post views are released as people scroll. Prepare upcoming
pictures and videos during scrolling; keep a video's poster visible until
AVPlayerLayer reports its first frame ready:

```swift
let prefetcher = PhotoPrefetcher(photos: photos)        // pictures, 3 at a time
FeedPager(items: posts, activeID: $activeId, lookahead: 4, loadMoreDistance: 8,
          onUpcoming: { next in
              prefetcher.prefetch(next.filter(\.isPhoto).map(\.mediaId), width: screenWidth)
              VideoPreloader.shared.preload(next.filter(\.isVideo).map(\.mediaId), videos: videos)
          },
          onActiveChanged: { post in
              VideoPreloader.shared.activate(post?.isVideo == true ? post?.mediaId : nil)
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
- `VideoPreloader` prepares up to four muted, paused players, requests a
  one-second forward buffer and runs AVFoundation preroll once ready. It
  also caches decoded posters. `bufferedIds` contains completed prerolls;
  `preparingIds` contains pending preparation, not a promise of downloaded data.
- Call `activate` synchronously from `onActiveChanged`, before `onUpcoming`
  prunes the old window. `VideoPlaybackModel` takes ownership of that same
  player, including when its preparation is still in flight. Backgrounding
  the feed should call `clear()`; memory warnings also release speculative work.
- On iOS 18 and later, completed prerolls also retain the decoder's first frame
  as the cover, without starting playback or opening a second decoder. Cells
  already mounted off screen receive that image before activation. Taking the
  player does not cancel an in-flight cover request. Brief first-frame waits
  display the cover without a spinner; a loading indicator appears after 300 ms
  if playback is still waiting. Failed and processing states remain explicit.
- Fast swipes and slow connections can outrun preparation. `RemoteVideoView`
  keeps a poster behind the video for the entire viewing session. The native
  player layer reveals a drawable frame without a SwiftUI poster-removal pass
  or opacity animation. On iOS 18 and later, `LoopingPlayer` provides a recent
  decoded frame that remains underneath the native
  surface across queue transitions. This backing image is bounded to 960 pixels
  on its longest side, sampled at most 12 times per second only while visible
  playback advances, and cleared when another player is assigned. Preloading
  never guarantees immediate playback.
- After a streamed video has been watched once, `VideoPlaybackModel` caches
  a copy for the next activation. The visible session keeps the same source
  and decoder for all its loops. It never clears the queue or swaps encoding
  while the person is watching. `LoopingPlayer.replaceAtNextLoop` is deprecated
  because an explicit source reset can interrupt rendering.


`RemotePhotoView` and `RemoteVideoView` accept `onReady` callbacks for
content-dependent onboarding. A photo reports readiness when its decoded
image appears; a video reports a visible poster or its first drawable frame.
Also check the pager's `isActive` and the feed's visibility: prefetched cells
can appear in the view hierarchy before they are the visible post. Loading,
empty and error states do not report content readiness.

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
if await feed.hideOwnPost(post) != nil { say("Hidden.", undo: { await feed.unhideOwnPost(post) }) }
if let deletion = await feed.deleteOwnPost(post) {                     // the post only, never its photo or video
    if let days = deletion.daysToRestore() { say("Deleted. You can restore it for \(days) days.") }
    else { say("Deleted.") }                                            // the author cannot bring it back
}

// 4a. "Hidden posts": the posts the person hid, Unhide and Delete.
@StateObject var hidden = HiddenPostsModel()
hidden.attach(social: social, currentUserId: user.id)
hidden.onUnhidden = { feed.showRestored($0) }                           // back in the feed, in its place
await hidden.load()                                                     // hidden.items: post, hiddenAt
await hidden.unhide(item)                                               // gone from the list at once; back with hidden.errorMessage if refused
await hidden.delete(item)                                               // same; the answer says whether the author can restore

// 4b. "Recently deleted", for an app whose authors restore: the days each post has left, Restore.
@StateObject var deleted = RecentlyDeletedModel()
deleted.attach(social: social, currentUserId: user.id)
deleted.onRestored = { feed.showRestored($0) }                          // back in the feed, in its place
await deleted.load()                                                    // deleted.items: post, restorableUntil, daysLeft()
await deleted.restore(item)                                             // gone at once; back with deleted.errorMessage if refused

// 5. Draw it: FeedPager (cells reused, next posts preloaded) and the media views.
FeedPager(items: feed.items, activeID: $activeId,
          onUpcoming: { next in
              prefetcher.prefetch(next.filter(\.isPhoto).map { (id: $0.mediaId, width: RemotePhotoView.requestWidth(wide: $0.isLandscape)) })
              VideoPreloader.shared.preload(next.filter(\.isVideo).map(\.mediaId), videos: videos)
          },
          onActiveChanged: { post in
              VideoPreloader.shared.activate(post?.isVideo == true ? post?.mediaId : nil)
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
- `deleteOwnPost` deletes the post and nothing else. Social hides it at once
  and keeps it, with its comments, likes, photo and video, for as many days as
  the app decided (30 unless it set something else; `PostDeletion.restorableUntil`
  says until when). After that Social removes the post for good and has its
  photo and video deleted in ScaleMule Photos and Video (unless another post
  of the author uses them); an app that keeps deleted posts for 0 days gets
  that right away. Never delete a post's media from the app
  (`PhotosService.delete`, `VideosService.delete`): a restored post would
  come back without its picture. A deleted video's copies on this phone are
  dropped; a failure keeps the post in the feed and sets `error`.
- Hide is not delete. `SocialService.hidePost(id:)` takes a post away from
  everyone, its author's own page and feed included, for as long as the
  author likes; `unhidePost(id:)` brings it back with its comments, likes,
  photo and video, and `hiddenPosts()` lists them (most recently hidden
  first). A hidden post has no end date. `HiddenPostsModel` is the list for a
  screen, with Unhide and Delete (each takes the post out at once and puts it
  back if the server refuses); `SocialFeedModel.hideOwnPost` and
  `unhideOwnPost` are the post menu's Hide and its Undo. An app that turned
  hiding off answers 403 with a sentence for the person.
- Whether a deleted post can come back is the app's rule, said with every
  delete (`PostDeletion.restorableBy`). Where it is `.team` or `.nobody` the
  post is gone for its author: say so before asking, show no way back
  (`daysToRestore()` is nil), and `deletedPosts()` lists nothing for them.
- `SocialService.deletedPosts()` lists the person's deleted posts that are
  still kept, `restorePost(id:)` brings one back. `RecentlyDeletedModel` is
  the list for a screen: it follows the app's rule (`canRestore` is false
  where only the app's team, or nobody, restores), removes a restored post at
  once and puts it back if the server refuses, and drops a post whose time
  ran out (410 `RESTORE_WINDOW_EXPIRED`, or 404). `SocialFeedModel.showRestored`
  puts a restored post back in the feed; `removeDeleted(postId:)` takes out a
  post another screen deleted.

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

## Push notifications on iOS

`ScaleMulePush` (also exported by `ScaleMule`) handles Apple's permission
prompt, APNs registration, ScaleMule device registration, foreground alerts,
sound and badges. Apps use the same SDK module; no Apple signing key belongs
in the application or SDK.

Create `PushNotifications(app: app)` once alongside your auth service. In a
SwiftUI app, use `@UIApplicationDelegateAdaptor(ScaleMulePushAppDelegate.self)`
and assign `appDelegate.pushNotifications = push` in the root's `onAppear`.
An app with its own delegate instead forwards `didRegister...deviceToken`
to `push.didRegister(deviceToken:)`, forwards the failure callback, and calls
`push.install()` early. The controller owns the notification-center delegate;
apps that already have one should explicitly forward its notification callbacks.

```swift
// Only after the person taps your Enable notifications button:
let allowed = await push.requestAuthorization() // alerts + badge + sound
// When the app becomes active or returns from iOS Settings:
await push.refresh() // no new permission prompt
// Before auth.logout() or permanent account deletion revokes the session:
await push.deactivateBeforeSignOut()
// If deletion fails and the same account remains signed in:
await push.resume()
```

Use `push.setEnabled(false)` for the device's off switch. Re-enabling restores
the server preference as well as registering with Apple. Observe `permission`,
`isEnabled`, `isRegistered`, `isWorking` and `lastError` for your settings UI.
The SDK observes auth changes, uses the user's session, and replaces previous
account bindings on this device. It never logs or persists the APNs token.
Only the server registration ID and local opt-in are retained. Failed cleanup
is surfaced; OS registration stops immediately. Delivery must also respect
server preferences and marketing consent. No broadcast or marketing opt-in is
created by calling the SDK.

Set `onNotificationTap` for app navigation. Cold-start taps wait for auth;
payloads with a different `recipient_user_id` are ignored. Payload URLs are
never opened automatically. Foreground presentation defaults to banner, list,
badge and sound; iOS permission, Focus and sound settings still apply. Call
`clearBadge()` when your app considers notifications seen; that does not mark
server inbox records read. Notifications are cleared from the device on logout.

Quiet hours are a server-enforced preference exposed by the SDK:

```swift
let push = PushNotifications(app: app, defaultQuietHours: .overnight)
// After authentication/registration, observe push.quietHours and its loading/error state.
await push.setQuietHours(PushQuietHours(startMinutes: 22 * 60, endMinutes: 8 * 60))
```

`.overnight` defaults to 22:00–08:00 only if the user has no saved preferences;
re-registering never overwrites a schedule or opt-out. A nil `timeZoneIdentifier`
follows each receiving device. A named IANA zone fixes the schedule to that zone.
`PushService.preferences()` and `setQuietHours(_:)` provide the lower-level APIs.
Use `quietHours.isQuiet()` for local presentation; the server decides delivery.

Continue calling `push.refresh()` when the app becomes active. Registration sends
`TimeZone.autoupdatingCurrent.identifier`, and the installed manager also refreshes
on system timezone changes. Travel is known once the device reconnects; no location
permission is needed. The server rechecks the latest timezone, schedule, opt-outs
and unread state before releasing queued pushes. Routine alerts wait; explicitly
urgent `alert` messages and silent updates follow their existing delivery policy.
Quiet hours do not replace the person's iOS Focus or sound settings.

Enable Push Notifications on the app's Apple App ID and signed target. Keep
the `aps-environment` entitlement consistent with its provisioning profile.
For the application's external ScaleMule vault, configure
`communication/push/apns` with `p8_key_base64`, `key_id`, `team_id`, `bundle_id`
and `is_production`. Development-signed builds use sandbox; TestFlight/App Store
use production. Check the signed archive, not just the source entitlement.

Send from a trusted server or the ScaleMule dashboard. The communication API's
`sound: "default"` requests the standard sound; `sound: ""` omits sound.
`badge: 3` sets an absolute count; `badge: 0` clears it. Custom sound filenames
must refer to a sound actually bundled with the app. This module does not
expose a mobile API for broadcasting or storing provider credentials.

The push resource bundle includes a privacy manifest for its own UserDefaults
usage and device/user identifiers. App privacy disclosures must also cover
the host app, backend and any other SDKs. Verify real background delivery,
sound, badge changes, permission denial and account cleanup on a signed device
before shipping; payload/unit tests are not proof of APNs delivery.

## Auth Credential Model

ScaleMule uses a multi-credential system, not a single bearer token:

- **Session token** — always present after login
- **Access token** (optional JWT) — only when refresh tokens are enabled
- **Refresh token** (optional) — only when refresh tokens are enabled

The SDK handles credential strategy per-endpoint automatically.

## License

MIT

## Digital gifting with StoreKit

Configure Catalog, Money Pricing, restricted Money Assets wallets and the app's
Apple products/server key first. The feature is disabled until configured.
Use the existing authenticated `ScaleMuleApp`; never embed an Apple private key
or an internal platform credential.

```swift
import ScaleMuleCommerce

// Keep these @MainActor objects alive for the signed-in session.
let commerce = CommerceService(app: app)
let purchases = AppleGiftStore(commerce: commerce)
let delivery = GiftDeliveryStore(commerce: commerce)

// After authentication, without blocking the app's first content load:
await purchases.start()
await delivery.start(userID: signedInUserID)

// Present from a deliberate user action:
GiftPickerView(store: purchases, delivery: delivery,
    recipientID: authorUserID, recipientName: authorDisplayName,
    contextType: "social_post", contextID: postID)
// Keep a catalog entry visible even on the user's own posts and from Settings.
// The host supplies real, authorized public identities and excludes self/blocks.
GiftPickerView(store: purchases, delivery: delivery, loadRecipients: {
    GiftRecipient.eligible(try await loadSocialRecipients(), currentUserID: signedInUserID)
})
CommerceWalletView(store: purchases)

// Tell the receiver. Refresh once `purchases.environment` is known and on
// every return to the foreground; present the arrival once, then mark it seen.
let received = ReceivedGiftsModel(commerce: commerce)
received.start(userID: signedInUserID)
await received.refresh(environment: environment)
if !received.unseen.isEmpty {
    let presented = received.unseen
    GiftArrivalView(gifts: presented, person: { await publicIdentity($0) }, seeAll: showReceivedGifts)
    // on dismiss: received.markSeen(giftIDs: presented.map(\.id))
}
ReceivedGiftsView(model: received, person: { await publicIdentity($0) })

// Brand every gift and credit screen once, on an ancestor of the views above.
// `onAccent` is the text color on accent buttons: a light accent needs a dark one.
.giftTheme(GiftTheme(accent: brandMint, onAccent: brandEvergreen))

// Foreground recovery:
await purchases.retryUnfinished()
await delivery.retryPending()

// Logout/account switch:
purchases.stop()
delivery.stop()
received.stop()
```

`AppleGiftStore` derives Production/Sandbox from Apple's verified app transaction
or a verified purchase with matching durable server fulfillment,
uses the server-issued `appAccountToken`, displays StoreKit's localized price,
and finishes a purchase only after matching durable server fulfillment. Pending
approval and cancellation grant nothing. Local Xcode StoreKit receipts cannot
fund server wallets; use Apple Sandbox/TestFlight for an integration test.

`GiftDeliveryStore` persists each operation before sending. An uncertain response
keeps the same operation for retry after relaunch. Do not create a new operation
for the same intended gift. The queue is partitioned by app key and user; stop
both stores before switching identities. App key rotation requires recovering
any old queue before dropping the old namespace.

An unavailable app-download receipt no longer blocks catalog browsing or the
normal StoreKit purchase sheet. `catalogProducts()` browses the production catalog
until Apple identifies the environment; this read-only choice never selects a
wallet or authorizes sending a gift. Balances and owned gifts wait for a verified
environment. Hosts should expose the shop based on Catalog configuration, not
on whether Apple has already verified the app receipt.

When the app receipt is unavailable, the SDK checks both purchase contexts and
offers only packs enabled with identical credit quantities in both environments,
with the same app, currency and account-token binding. `Product.purchase` can then
perform Apple's normal authentication. An explicitly unverified receipt or local
StoreKit environment still blocks checkout. Verified purchase transactions are
bound to the app/account and independently verified by the server before delivery;
test money never becomes production money. If either environment is disabled,
Apple must identify the environment before checkout can be enabled.

`needsAppStoreConnection` stays true until verification succeeds. The wallet offers
an optional **Check Apple account** action for existing balances. Custom views
must call `connectToAppStore()` only after an explicit tap: Apple's
`AppTransaction.refresh()` may display its sign-in sheet. Automatic `start()`
never invokes that prompt. Product-loading failures remain retryable. Xcode and
TestFlight installations still use Apple's testing environment; publication uses
production. A server flag cannot change an installation's signing/distribution.

`ReceivedGiftsView` pages through the full history and supports pull-to-refresh.
Custom collection views can use `hasMore`, `isLoading`, `errorMessage` and
`loadMore()`. A failed refresh preserves the last loaded collection. Acknowledge
the IDs captured when presenting an arrival, so a later gift stays unread.
Refresh on a matching `PushNotifications.onForegroundNotification`, on a tap,
and on foreground resume. If notification permission is off, a bounded refresh
while active can keep the collection current; stop it in the background.

`CommerceService` is usable without the provided views. The shared views inherit
your app tint, keep artwork visible, and offer optional muted MP4 gift animation
with Reduced Motion support. Owned gifts do not have monetary redemption value.
Inventory confirms receipt; this module does not itself send gift push messages.

### Durable notification Inbox and badge policy

`NotificationInboxService(app:)` reads `/v1/communication/notifications`, gets the unread
count, and marks an individual item or the whole Inbox read using the signed-in
session. `NotificationInboxModel` supplies published items, pagination, unread
count, loading/error states and optional polling. Attach it with the signed-in
user ID; reset it at sign-out. In-flight responses from an earlier account are
ignored. Load/refresh do not mark anything read. Call `markRead(id:)` only when
an item is viewed or its push is tapped; failures retain its unread state.
For an Activity screen that acknowledges updates on entry, call `markAllRead()`
once when it becomes visible (or from Mark all as read). This clears the whole
server backlog, including unloaded pages, while retaining browsable history.
It does not change chat read receipts. `isMarkingAllRead` supports progress UI.
First-page refreshes retain earlier pages, and responses started before a bulk
acknowledgement are refetched to avoid reviving stale unread rows.

The OS icon and the Inbox are independent. `push.clearBadge()` sets only the
home-screen icon to zero. `push.setBadgeCount(count)` sets an absolute,
nonnegative count and reports success. Neither method marks messages or Inbox
items read. An app that clears on activation should omit `.badge` from
`foregroundPresentationOptions` and refresh its Inbox on foreground delivery.
A general push should navigate to its Inbox content, not an unrelated feed.

On the server, a direct push for a registered user creates one durable item per
send/user, shared across their devices. Its `notification_id` travels with the
push. Apple alerts for durable items default to the current unread notification
count; native events with separate read state use an attention badge. Explicit
server `badge` values (including `0`) take precedence. Badge permission, sound
preferences and Focus remain controlled by iOS. None of this is an aggregate
read count across separate chat, social and gift stores.
