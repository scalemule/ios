import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleStorage
@testable import ScaleMuleVideos

final class VideosServiceTests: XCTestCase {
    private func signedIn() async -> VideosService {
        let (app, session) = createTestClient()
        try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600)))
        let storage = StorageService(
            client: app.client,
            conditions: NetworkConditions(fixed: NetworkSnapshot(interface: .wifi, isExpensive: false, isConstrained: false, measuredUplinkMbps: nil)),
            s3Session: session,
            resumeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("sm-videos-\(UUID().uuidString)"),
            retryDelays: [0, 0, 0]
        )
        return VideosService(client: app.client, storage: storage)
    }

    func testUploadSendsTheFileUnchangedThenRegisters() async {
        let videos = await signedIn()
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if url.host == "s3.test" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
            switch url.path {
            case "/v1/storage/signed-url/upload":
                let body = self.bodyJSON(request)
                XCTAssertEqual(body?["content_type"] as? String, "video/mp4")
                XCTAssertEqual(body?["visibility"] as? String, "private")
                XCTAssertEqual(body?["size_bytes"] as? Int, 400_000, "videos are sent as compressed on the phone")
                return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{"file_id":"vid-1","upload_url":"https://s3.test/v","completion_token":"t"}}"#)
            case "/v1/storage/signed-url/complete":
                return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{"file_id":"vid-1","filename":"clip.mp4","size_bytes":400000,"content_type":"video/mp4","visibility":"private"}}"#)
            case "/v1/videos/register":
                XCTAssertEqual(self.bodyJSON(request)?["file_id"] as? String, "vid-1")
                // Video answers without the usual envelope.
                return TestFixtures.mockResponse(statusCode: 202, json: #"{"video_id":"vid-1","file_id":"vid-1","status":"pending_scan","original_view_url":null}"#)
            default:
                return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{}}"#)
            }
        }
        let video = assertApiSuccess(await videos.upload(Data(repeating: 1, count: 400_000), filename: "clip.mp4"))
        XCTAssertEqual(video?.videoId, "vid-1")
        XCTAssertEqual(video?.status, "pending_scan")
    }

    func testPlaybackURLCarriesAShortLivedToken() async {
        let videos = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/videos/vid-1/embed-token")
            XCTAssertEqual(self.bodyJSON(request)?["expires_in"] as? Int, 3600)
            return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{"token":"tok.abc","expires_at":1}}"#)
        }
        let url = assertApiSuccess(await videos.playbackURL(id: "vid-1"))
        XCTAssertEqual(url?.path, "/v1/videos/vid-1/playlist.m3u8")
        XCTAssertEqual(URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "tok.abc")
    }

    func testGetReadsStatusDurationAndPoster() async {
        let videos = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/videos/vid-1")
            return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{"id":"vid-1","status":"ready","duration_seconds":12.5,"width":1080,"height":1920,"thumbnail_url":"https://cdn.test/t.jpg","playlist_url":"/v1/videos/vid-1/playlist.m3u8"}}"#)
        }
        let info = assertApiSuccess(await videos.get(id: "vid-1"))
        XCTAssertEqual(info?.isReady, true)
        XCTAssertEqual(info?.durationSeconds, 12.5)
        XCTAssertEqual(info?.height, 1920)
        XCTAssertEqual(info?.thumbnailUrl, "https://cdn.test/t.jpg")
    }

    #if canImport(UIKit)
    // VideoPlaybackModel is iOS only; `swift test` on macOS builds without it.
    @MainActor
    func testSoundOnIsHeardOnSilentAndMutedLeavesOtherAudio() {
        XCTAssertEqual(VideoPlaybackModel.audioCategory(muted: false), .playback)
        XCTAssertEqual(VideoPlaybackModel.audioCategory(muted: true), .ambient)
        // play() itself must use it (a merge once put .ambient back there).
        let (app, _) = createTestClient()
        PlaybackAnalytics.isEnabled = false
        defer { PlaybackAnalytics.isEnabled = true }
        let model = VideoPlaybackModel(videoId: "v", videos: VideosService(app: app))
        model.isMuted = false
        model.play()
        XCTAssertEqual(model.appliedAudioCategory, .playback)
        model.stop()
        model.isMuted = true
        model.play()
        XCTAssertEqual(model.appliedAudioCategory, .ambient)
        model.stop()
    }

    func testTrackSendsTheDashboardFields() async {
        let (app, _) = createTestClient()
        try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "sess", sessionExpiresAt: Date().addingTimeInterval(3600)))
        let videos = VideosService(app: app)
        var body: [String: Any]?
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/videos/v1/track")
            body = self.bodyJSON(request)
            return TestFixtures.mockResponse(statusCode: 202, json: #"{"success":true,"event_id":"e"}"#)
        }
        let event = PlaybackEvent(sessionId: "ios-1", type: .heartbeat, positionSeconds: 3.2, quality: "480p",
                                  metadata: ["watched_seconds": AnyCodable(12.5), "watch_through_ratio": AnyCodable(1.0)])
        _ = await videos.track(id: "v1", event: event)
        XCTAssertEqual(body?["event_type"] as? String, "heartbeat")
        XCTAssertEqual(body?["session_id"] as? String, "ios-1")
        XCTAssertEqual(body?["quality"] as? String, "480p")
        XCTAssertEqual((body?["metadata"] as? [String: Any])?["watched_seconds"] as? Double, 12.5)
    }
    #endif
}
