#if os(iOS)
import AVFoundation
import UIKit
import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleVideos
@testable import ScaleMuleMediaEditing

final class VideoShareTests: XCTestCase {
    private let master = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=480x854,CODECS="avc1.64002a,mp4a.40.2"
    /v1/videos/v1/stream/480p/index.m3u8?token=t
    #EXT-X-STREAM-INF:BANDWIDTH=600000,RESOLUTION=360x640
    /v1/videos/v1/stream/360p/index.m3u8?token=t
    #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=720x1280
    /v1/videos/v1/stream/720p/index.m3u8?token=t
    #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1080x1920
    /v1/videos/v1/stream/1080p/index.m3u8?token=t
    """
    private let media = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-TARGETDURATION:2
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXT-X-MAP:URI="https://assets.example.com/videos/v1/hls/1080p/segments.m4s",BYTERANGE="800@0"
    #EXTINF:2.002,
    #EXT-X-BYTERANGE:5000@800
    https://assets.example.com/videos/v1/hls/1080p/segments.m4s
    #EXTINF:1.0,
    #EXT-X-BYTERANGE:3000@5800
    https://assets.example.com/videos/v1/hls/1080p/segments.m4s
    #EXT-X-ENDLIST
    """

    func testPicksTheBestQualityUpToTheLimit() {
        let base = URL(string: "https://api.example.com/v1/videos/v1/playlist.m3u8?token=t")!
        XCTAssertEqual(HLSPlaylist.bestVariant(in: master, base: base, maxShortSide: 1080)?.path, "/v1/videos/v1/stream/1080p/index.m3u8")
        XCTAssertEqual(HLSPlaylist.bestVariant(in: master, base: base, maxShortSide: 720)?.path, "/v1/videos/v1/stream/720p/index.m3u8")
        XCTAssertEqual(HLSPlaylist.bestVariant(in: master, base: base, maxShortSide: 100)?.path, "/v1/videos/v1/stream/360p/index.m3u8", "else the smallest")
        XCTAssertEqual(HLSPlaylist.bestVariant(in: master, base: base, maxShortSide: 1080)?.host, "api.example.com")
    }

    func testOneFileBehindByteRangeSegments() {
        let files = HLSPlaylist.files(in: media, base: URL(string: "https://api.example.com/x/index.m3u8")!)
        XCTAssertEqual(files.map(\.absoluteString), ["https://assets.example.com/videos/v1/hls/1080p/segments.m4s"])
        let split = HLSPlaylist.files(in: "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:2,\nseg0.m4s\n#EXTINF:2,\nseg1.m4s\n", base: URL(string: "https://cdn.example.com/a/index.m3u8")!)
        XCTAssertEqual(split.map(\.lastPathComponent), ["init.mp4", "seg0.m4s", "seg1.m4s"])
    }

    @MainActor
    func testSharedFileIsAPlainMP4WithoutLocation() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "fragmented", withExtension: "mp4", subdirectory: "Fixtures"))
        let bytes = try Data(contentsOf: fixture)
        // The fixture really carries a location (the test proves it goes).
        let sourceMetadata = try await AVURLAsset(url: fixture).load(.metadata)
        XCTAssertFalse(sourceMetadata.isEmpty)
        let (app, session) = createTestClient()
        try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "sess", sessionExpiresAt: Date().addingTimeInterval(3600)))
        let videoId = "share-\(UUID().uuidString)"
        let media = self.media.replacingOccurrences(of: "v1/hls", with: "\(videoId)/hls")
        let master = self.master
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if url.path.hasSuffix("/embed-token") {
                return TestFixtures.envelopedResponse(json: #"{"token":"t","expires_at":9999999999}"#)
            }
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if url.path.hasSuffix("/playlist.m3u8") { return (ok, Data(master.utf8)) }
            if url.path.hasSuffix("/1080p/index.m3u8") { return (ok, Data(media.utf8)) }
            if url.path.hasSuffix("segments.m4s") { return (ok, bytes) }
            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        let file = try await VideoShareFile.file(for: videoId, videos: VideosService(app: app), session: session)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(file.pathExtension, "mp4")
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        let sourceDuration = try await AVURLAsset(url: fixture).load(.duration).seconds
        XCTAssertEqual(duration, sourceDuration, accuracy: 0.2)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(videoTracks.isEmpty)
        XCTAssertFalse(audioTracks.isEmpty, "sound kept")
        let metadata = try await asset.load(.metadata)
        let location = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeMetadataLocationISO6709)
            + AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeUserDataLocationISO6709)
        XCTAssertTrue(location.isEmpty, "no location in a shared file")
        XCTAssertTrue(metadata.isEmpty, "no metadata at all: \(metadata.map { String(describing: $0.identifier) })")
        // Asked again: the kept file, no download.
        MockURLProtocol.requestHandler = { _ in XCTFail("downloaded twice"); throw URLError(.badURL) }
        let again = try await VideoShareFile.file(for: videoId, videos: VideosService(app: app), session: session)
        XCTAssertEqual(again, file)
    }

    func testLogoIsBottomRightAndUpright() async throws {
        let clip = try XCTUnwrap(Bundle.module.url(forResource: "portrait-1", withExtension: "mov", subdirectory: "Fixtures"))
        // A mark whose top half is solid and bottom half empty: upright means
        // the solid half shows above the empty one.
        let mark = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 50))
        }
        let marked = try await MediaExport.watermarkedVideo(clip, mark: mark)
        defer { try? FileManager.default.removeItem(at: marked) }
        let original = try await frame(clip)
        let withMark = try await frame(marked)
        XCTAssertEqual(original.width, withMark.width)
        XCTAssertEqual(original.height, withMark.height)
        let w = Double(withMark.width), h = Double(withMark.height), shorter = min(w, h)
        let logoW = max(shorter * 0.24, 96), logoH = logoW / 2, margin = shorter * 0.035
        let left = w - logoW - margin, top = h - logoH - margin
        // Inside the mark: upper half much brighter than the original, lower half about the same.
        let upper = brightness(withMark, x: left + logoW * 0.3, y: top + logoH * 0.25) - brightness(original, x: left + logoW * 0.3, y: top + logoH * 0.25)
        let lower = brightness(withMark, x: left + logoW * 0.3, y: top + logoH * 0.8) - brightness(original, x: left + logoW * 0.3, y: top + logoH * 0.8)
        let farCorner = brightness(withMark, x: w * 0.1, y: h * 0.1) - brightness(original, x: w * 0.1, y: h * 0.1)
        XCTAssertGreaterThan(upper, 0.25, "solid half of the mark at the bottom right")
        XCTAssertLessThan(abs(lower), 0.15, "empty half below it: upright, not flipped")
        XCTAssertLessThan(abs(farCorner), 0.08, "rest of the picture unchanged")
        let metadata = try await AVURLAsset(url: marked).load(.metadata)
        XCTAssertTrue(metadata.isEmpty)
        let markedAudio = try await AVURLAsset(url: marked).loadTracks(withMediaType: .audio)
        XCTAssertFalse(markedAudio.isEmpty, "sound kept")
    }

    private func frame(_ url: URL) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
    }

    /// 0...1 brightness of a pixel (x, y from the top left).
    private func brightness(_ image: CGImage, x: Double, y: Double) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(Double(image.height) - y - 1), width: Double(image.width), height: Double(image.height)))
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 765
    }
}
#endif
