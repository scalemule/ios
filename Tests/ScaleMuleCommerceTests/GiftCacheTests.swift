import XCTest
import ImageIO
import ScaleMuleCore
import ScaleMuleTestHelpers
@testable import ScaleMuleCommerce

final class GiftCacheTests: XCTestCase {
    @MainActor
    func testCatalogueLifetimeEnvironmentPaginationAndClear() async throws {
        var time: TimeInterval = 0
        var calls = 0
        let cache = GiftCatalogCache(now: { time })
        let product = try JSONDecoder().decode(GiftProduct.self, from: Data(CommerceTests.product.utf8))
        let load: @MainActor () async -> ApiResponse<[GiftProduct]> = { calls += 1; return .success([product]) }
        _ = await cache.products(environment: .production, load: load)
        time = 299
        _ = await cache.products(environment: .production, load: load)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(cache.snapshot(environment: .production)?.first?.id, product.id)
        _ = await cache.products(environment: .sandbox, load: load)
        _ = await cache.products(environment: .production, before: "next", load: load)
        XCTAssertEqual(calls, 3)
        time = 300
        XCTAssertNil(cache.snapshot(environment: .production))
        _ = await cache.products(environment: .production, load: load)
        XCTAssertEqual(calls, 4)
        cache.clear()
        XCTAssertNil(cache.snapshot(environment: .sandbox))
        _ = await cache.products(environment: .production, load: load)
        XCTAssertEqual(calls, 5)
    }

    @MainActor
    func testConcurrentCatalogueReadsCoalesceAndSignOutRejectsAllWaiters() async {
        let cache = GiftCatalogCache()
        var resume: CheckedContinuation<ApiResponse<[GiftProduct]>, Never>?
        var calls = 0
        let load: @MainActor () async -> ApiResponse<[GiftProduct]> = {
            calls += 1
            return await withCheckedContinuation { resume = $0 }
        }
        let first = Task { await cache.products(environment: .production, load: load) }
        while resume == nil { await Task.yield() }
        let second = Task { await cache.products(environment: .production, load: load) }
        // Ensure the second caller has entered the shared pending request.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls, 1)
        cache.clear()
        resume?.resume(returning: .success([]))
        let a = await first.value, b = await second.value
        XCTAssertFalse(a.isSuccess); XCTAssertFalse(b.isSuccess)
        XCTAssertNil(cache.snapshot(environment: .production))
    }

    @MainActor
    func testFailedCatalogueReadIsRetriedAndEmptyCatalogueIsCached() async {
        let cache = GiftCatalogCache()
        var calls = 0
        let load: @MainActor () async -> ApiResponse<[GiftProduct]> = {
            calls += 1
            return calls == 1 ? .failure(ApiError(code: .networkError, message: "Offline")) : .success([])
        }
        _ = await cache.products(environment: .production, load: load)
        XCTAssertNil(cache.snapshot(environment: .production))
        _ = await cache.products(environment: .production, load: load)
        _ = await cache.products(environment: .production, load: load)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(cache.snapshot(environment: .production)?.count, 0)
    }

    @MainActor
    func testArtworkCoalescesDownsamplesAndReadsDiskWithoutNetwork() async throws {
        let data = try artwork()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = GiftArtworkCache(folder: folder, session: session)
        let url = URL(string: "https://example.com/art.png")!
        var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!, data)
        }
        async let a = cache.load(url: url)
        async let b = cache.load(url: url)
        let results = await (a, b)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(results.0?.width, 320)
        XCTAssertEqual(results.1?.height, 160)
        XCTAssertNotNil(cache.image(url: url))
        XCTAssertNotEqual(results.0?.alphaInfo, CGImageAlphaInfo.none)
        let reopened = GiftArtworkCache(folder: folder, session: session)
        let saved = await reopened.load(url: url)
        XCTAssertEqual(saved?.width, 320)
        XCTAssertEqual(requests, 1, "Reopening with no decoded images must use disk")
        let later = GiftArtworkCache(folder: folder, session: session, now: { Date().addingTimeInterval(86401) })
        _ = await later.load(url: url)
        XCTAssertEqual(requests, 2, "Expired artwork must refresh")
    }

    @MainActor
    func testFailedArtworkIsNotCached() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = GiftArtworkCache(folder: folder, session: URLSession(configuration: configuration))
        let url = URL(string: "https://example.com/missing.png")!
        var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }
        _ = await cache.load(url: url)
        _ = await cache.load(url: url)
        XCTAssertEqual(requests, 2)
        XCTAssertNil(cache.image(url: url))
    }

    @MainActor
    func testLiveArtworkColdDiskAndMemoryTiming() async throws {
        guard let value = ProcessInfo.processInfo.environment["GIFT_CACHE_LIVE_URL"], let url = URL(string: value) else {
            throw XCTSkip("Optional read-only check against real catalogue artwork")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = GiftArtworkCache(folder: folder)
        let start = ProcessInfo.processInfo.systemUptime
        let cold = await cache.load(url: url)
        let fetched = ProcessInfo.processInfo.systemUptime
        let warm = cache.image(url: url)
        let memory = ProcessInfo.processInfo.systemUptime
        let reopened = GiftArtworkCache(folder: folder)
        let disk = await reopened.load(url: url)
        let end = ProcessInfo.processInfo.systemUptime
        XCTAssertNotNil(cold); XCTAssertNotNil(warm); XCTAssertNotNil(disk)
        XCTAssertLessThanOrEqual(try XCTUnwrap(cold).width, 320)
        print("GIFT_CACHE_TIMING cold_ms=\((fetched-start)*1000) memory_ms=\((memory-fetched)*1000) disk_ms=\((end-memory)*1000)")
    }

    private func artwork() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1024, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.8, blue: 0.6, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 512))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
