#if canImport(UIKit)
import AVFoundation
import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleStorage
@testable import ScaleMulePhotos
@testable import ScaleMuleVideos
@testable import ScaleMuleMediaEditing
@testable import ScaleMuleMediaQueue

/// Copies of the fixture clips (the queue takes files over).
private func clip(_ seconds: Int, name: String = "portrait") throws -> URL {
    let source = try XCTUnwrap(Bundle.module.url(forResource: "\(name)-\(seconds)", withExtension: "mov", subdirectory: "Fixtures"))
    let copy = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).mov")
    try FileManager.default.copyItem(at: source, to: copy)
    return copy
}

final class VideoComposerTests: XCTestCase {
    func testJoinsClipsTrimsAndKeepsPortrait() async throws {
        let clips = [try clip(1), try clip(2)]
        let total = try await VideoComposer.duration(of: clips)
        XCTAssertEqual(total, 3, accuracy: 0.1)

        var edit = VideoEdit(clips: clips)
        edit.trimStart = 0.5
        edit.trimEnd = 2.5
        let prepared = try await VideoComposer.export(edit)
        XCTAssertEqual(prepared.duration, 2, accuracy: 0.15)
        XCTAssertLessThan(prepared.width, prepared.height, "portrait stays portrait")
        XCTAssertLessThan(prepared.poster.size.width, prepared.poster.size.height)
        let audio = try await AVURLAsset(url: prepared.file).loadTracks(withMediaType: .audio)
        XCTAssertFalse(audio.isEmpty, "sound kept")
    }

    func testLookAndMute() async throws {
        let edit = VideoEdit(clips: [try clip(1)], look: .noir, muted: true)
        let prepared = try await VideoComposer.export(edit)
        let asset = AVURLAsset(url: prepared.file)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty, "muted video has no sound")
        XCTAssertLessThan(prepared.width, prepared.height, "the look keeps portrait frames upright")
        // Noir: the poster has no colour.
        let cg = try XCTUnwrap(prepared.poster.cgImage)
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var spread = 0
        for i in stride(from: 0, to: 8 * 8 * 4, by: 4) {
            spread = max(spread, Int(max(pixels[i], pixels[i + 1], pixels[i + 2])) - Int(min(pixels[i], pixels[i + 1], pixels[i + 2])))
        }
        XCTAssertLessThan(spread, 12, "noir frames are grey")
    }

    func testClipsWhoseSoundRunsLongerJoinWithoutGaps() async throws {
        // 1.0 s of picture with 1.4 s of sound, then 1 s: 2.0 s, not 2.4.
        let clips = [try clip(1, name: "longsound"), try clip(1)]
        let joined = try await VideoComposer.duration(of: clips)
        XCTAssertEqual(joined, 2.0, accuracy: 0.08)
        let prepared = try await VideoComposer.export(VideoEdit(clips: clips))
        XCTAssertEqual(prepared.duration, 2.0, accuracy: 0.12)
    }

    func testTrimIsClampedAndLimited() throws {
        let total = CMTime(seconds: 90, preferredTimescale: 600)
        var edit = VideoEdit(clips: [])
        edit.trimStart = 10
        let range = VideoComposer.trimmedRange(edit, total: total, maxSeconds: 60)
        XCTAssertEqual(range.start.seconds, 10, accuracy: 0.01)
        XCTAssertEqual(range.end.seconds, 70, accuracy: 0.01, "at most 60 s")
        edit.trimStart = 200
        XCTAssertLessThan(VideoComposer.trimmedRange(edit, total: total, maxSeconds: 60).start.seconds, 90)
    }
}

final class MediaHelpersTests: XCTestCase {
    @MainActor
    func testImageCacheKeepsPicturesOnDisk() async throws {
        let folder = "test-cache-\(UUID().uuidString)"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let first = PhotoImageCache(folderName: folder)
        first.store(image, for: PhotoImageCache.key(for: "p1"))
        try await Task.sleep(nanoseconds: 300_000_000)
        let second = PhotoImageCache(folderName: folder)
        let saved = await second.saved(for: PhotoImageCache.key(for: "p1"))
        // Same pixels (the cache keeps them; screen scale is not stored).
        XCTAssertEqual(saved?.cgImage?.width, image.cgImage?.width)
        XCTAssertEqual(saved?.cgImage?.height, image.cgImage?.height)
    }

    func testWatermarkKeepsSize() {
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 900)).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
        }
        let mark = UIImage(systemName: "star.fill")!
        XCTAssertEqual(MediaExport.watermarked(photo, mark: mark).size, photo.size)
    }
}

/// Storage + Photos + Video + an app's publish step, against a fake server.
final class MediaUploadQueueTests: XCTestCase {
    private final class Server: @unchecked Sendable {
        let lock = NSLock()
        var paths: [String] = []
        var deletes = 0
        func record(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
        func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return paths.filter { $0 == path }.count }
    }

    private func services(_ server: Server, registerDelay: TimeInterval = 0) async -> (PhotosService, VideosService) {
        let (app, session) = createTestClient()
        try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "sess", sessionExpiresAt: Date().addingTimeInterval(3600)))
        let storage = StorageService(
            client: app.client,
            conditions: NetworkConditions(fixed: NetworkSnapshot(interface: .wifi, isExpensive: false, isConstrained: false, measuredUplinkMbps: nil)),
            s3Session: session,
            resumeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString)"),
            retryDelays: [0, 0, 0]
        )
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            server.record(url.host == "s3.test" ? "s3" : url.path)
            if request.httpMethod == "DELETE" { server.lock.lock(); server.deletes += 1; server.lock.unlock() }
            if url.host == "s3.test" { return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"e\""])!, Data()) }
            let json: String
            switch url.path {
            case "/v1/storage/signed-url/upload":
                json = #"{"success":true,"data":{"file_id":"f1","upload_url":"https://s3.test/x","completion_token":"t"}}"#
            case "/v1/storage/signed-url/complete":
                json = #"{"success":true,"data":{"file_id":"f1","filename":"x","size_bytes":1,"content_type":"image/jpeg","visibility":"private"}}"#
            case "/v1/photos/register":
                if registerDelay > 0 { Thread.sleep(forTimeInterval: registerDelay) }
                json = #"{"success":true,"data":{"id":"photo-1","filename":"x.jpg","mime_type":"image/jpeg","file_size":1,"width":4032,"height":3024,"created_at":"2026-11-22T00:00:00Z"}}"#
            case "/v1/videos/register":
                json = #"{"video_id":"video-1","file_id":"f1","status":"registering"}"#
            default:
                json = #"{"success":true,"data":{}}"#
            }
            return TestFixtures.mockResponse(statusCode: 200, json: json)
        }
        return (PhotosService(client: app.client, storage: storage), VideosService(client: app.client, storage: storage))
    }

    @MainActor
    private func waitFor(_ condition: @escaping () -> Bool, seconds: Double = 20) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    @MainActor
    func testPhotoUploadsThenPublishesAndRetryReusesTheUpload() async throws {
        let server = Server()
        let (photos, videos) = await services(server)
        let folder = "queue-\(UUID().uuidString)"
        var published: [MediaUpload] = []
        var failFirst = true
        let queue = MediaUploadQueue(photos: photos, videos: videos, folderName: folder) { upload in
            if failFirst {
                failFirst = false
                return .failure(.init("Social is down"))
            }
            published.append(upload)
            return .success(())
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        queue.post(photo: image, attributes: ["caption": "Ocean Beach 🌊"])
        await waitFor { queue.jobs.first.map { if case .failed = $0.state { return true }; return false } ?? false }
        XCTAssertEqual(queue.jobs.first?.state, .failed("Social is down"))
        XCTAssertEqual(server.count("/v1/photos/register"), 1)

        queue.retry(try XCTUnwrap(queue.jobs.first?.id))
        await waitFor { queue.jobs.isEmpty }
        XCTAssertEqual(published.first?.mediaId, "photo-1")
        XCTAssertEqual(published.first?.attributes["caption"], "Ocean Beach 🌊")
        XCTAssertEqual(server.count("/v1/photos/register"), 1, "publishing again reuses the uploaded photo")
    }

    @MainActor
    func testDiscardingDuringUploadPublishesNothingAndLeavesNothing() async throws {
        let server = Server()
        let (photos, videos) = await services(server, registerDelay: 0.8)
        let folder = "queue-\(UUID().uuidString)"
        var published = 0
        let queue = MediaUploadQueue(photos: photos, videos: videos, folderName: folder) { _ in
            published += 1
            return .success(())
        }
        queue.post(photo: UIImage(systemName: "star.fill")!, attributes: [:])
        await waitFor { server.count("/v1/photos/register") > 0 || server.count("s3") > 0 }
        queue.discard(try XCTUnwrap(queue.jobs.first?.id))
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(published, 0, "a discarded post is never published")
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(folder)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(left.isEmpty, "nothing left to come back after a relaunch: \(left)")
        XCTAssertGreaterThan(server.deletes, 0, "the photo uploaded meanwhile is deleted")
    }

    @MainActor
    func testAnUnfinishedPostCarriesOnAfterRelaunch() async throws {
        let server = Server()
        let (photos, videos) = await services(server)
        let folder = "queue-\(UUID().uuidString)"
        let first = MediaUploadQueue(photos: photos, videos: videos, folderName: folder) { _ in .failure(.init("offline")) }
        first.post(photo: UIImage(systemName: "star.fill")!, attributes: ["caption": "later"])
        await waitFor { first.jobs.first.map { if case .failed = $0.state { return true }; return false } ?? false }

        var published: [MediaUpload] = []
        let relaunched = MediaUploadQueue(photos: photos, videos: videos, folderName: folder) { upload in
            published.append(upload)
            return .success(())
        }
        relaunched.restore()
        await waitFor { !published.isEmpty }
        XCTAssertEqual(published.first?.attributes["caption"], "later")
        XCTAssertEqual(server.count("/v1/photos/register"), 1, "uploaded once, published after the relaunch")
    }

    @MainActor
    func testVideoTakeIsJoinedUploadedAndPublished() async throws {
        let server = Server()
        let (photos, videos) = await services(server)
        var published: [MediaUpload] = []
        let queue = MediaUploadQueue(photos: photos, videos: videos, folderName: "queue-\(UUID().uuidString)") { upload in
            published.append(upload)
            return .success(())
        }
        let clips = [try clip(1), try clip(2)]
        queue.post(video: VideoEdit(clips: clips, trimEnd: 2.5), attributes: ["caption": "two cuts"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: clips[0].path), "the queue took the clips over")
        await waitFor({ !published.isEmpty }, seconds: 60)
        let upload = try XCTUnwrap(published.first)
        XCTAssertEqual(upload.kind, .video)
        XCTAssertEqual(upload.mediaId, "video-1")
        XCTAssertEqual(upload.duration ?? 0, 2.5, accuracy: 0.2)
        XCTAssertLessThan(upload.width, upload.height)
        XCTAssertNotNil(VideoFileCache.file(for: "video-1"), "your own video plays from the phone at once")
    }
}
#endif
