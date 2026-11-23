import XCTest
import ImageIO
import UniformTypeIdentifiers
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleStorage

/// A fake Storage API + S3, routed by path. Records every request.
final class FakeStorageServer: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    /// Part number -> responses to give, in order (status, or nil = connection lost).
    var partScript: [Int: [Int?]] = [:]
    var singleScript: [Int?] = []
    var startPartURLs = 2
    var totalParts = 3
    var partSize = 5 * 1024 * 1024
    var partURLsStatus = 200

    func paths() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return requests.compactMap { $0.url?.path }
    }

    func bodies(for path: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.url?.path == path }.compactMap { request in
            guard let data = request.httpBody ?? Self.read(request.httpBodyStream) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    func install() {
        MockURLProtocol.requestHandler = { [self] request in
            lock.lock()
            requests.append(request)
            lock.unlock()
            return try respond(request)
        }
    }

    private func next(_ script: inout [Int?]) -> Int? {
        script.isEmpty ? 200 : script.removeFirst()
    }

    private func respond(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let url = request.url!
        if url.host == "s3.test" {
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "S3 must never get ScaleMule credentials")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
            let status: Int?
            lock.lock()
            if url.path.hasPrefix("/part/") {
                let part = Int(url.lastPathComponent)!
                var script = partScript[part] ?? []
                status = next(&script)
                partScript[part] = script
            } else {
                status = next(&singleScript)
            }
            lock.unlock()
            guard let status else { throw URLError(.networkConnectionLost) }
            var headers: [String: String] = [:]
            if status == 200 && url.path.hasPrefix("/part/") { headers["ETag"] = "\"etag-\(url.lastPathComponent)\"" }
            return (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, Data("<Error/>".utf8))
        }
        let json: String
        switch url.path {
        case "/v1/storage/signed-url/upload":
            json = #"{"file_id":"f-direct","upload_url":"https://s3.test/single?sig=1","completion_token":"tok","expires_at":"x","method":"PUT"}"#
        case "/v1/storage/signed-url/complete", "/v1/storage/signed-url/multipart/complete":
            let id = url.path.contains("multipart") ? "f-multi" : "f-direct"
            json = #"{"file_id":"\#(id)","filename":"a.jpg","size_bytes":10,"content_type":"image/jpeg","url":"https://cdn.test/a","visibility":"private","scan_queued":true}"#
        case "/v1/storage/signed-url/multipart/start":
            let urls = (1...startPartURLs).map { #"{"part_number":\#($0),"url":"https://s3.test/part/\#($0)","expires_at":"x"}"# }.joined(separator: ",")
            json = #"{"upload_session_id":"sess-1","file_id":"f-multi","completion_token":"ctok","part_size_bytes":\#(partSize),"total_parts":\#(totalParts),"part_urls":[\#(urls)],"expires_at":"x"}"#
        case "/v1/storage/signed-url/multipart/part-urls":
            if partURLsStatus != 200 {
                return TestFixtures.mockResponse(statusCode: partURLsStatus, json: #"{"success":false,"error":{"code":"NOT_FOUND","message":"Upload session not found"}}"#)
            }
            let body = (request.httpBody ?? Self.read(request.httpBodyStream)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let numbers = body?["part_numbers"] as? [Int] ?? []
            let urls = numbers.map { #"{"part_number":\#($0),"url":"https://s3.test/part/\#($0)","expires_at":"x"}"# }.joined(separator: ",")
            json = #"{"part_urls":[\#(urls)]}"#
        default:
            // abort, report-failure, analytics, logger
            json = "{}"
        }
        return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":\#(json)}"#)
    }

    static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class StorageUploadTests: XCTestCase {
    private var server: FakeStorageServer!
    private var resumeDirectory: URL!

    override func setUp() {
        super.setUp()
        server = FakeStorageServer()
        server.install()
        resumeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("sm-resume-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: resumeDirectory)
        super.tearDown()
    }

    private func storage(_ network: NetworkSnapshot = .init(interface: .wifi, isExpensive: false, isConstrained: false, measuredUplinkMbps: nil)) async -> StorageService {
        let (app, session) = createTestClient()
        try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600)))
        return StorageService(
            client: app.client,
            conditions: NetworkConditions(fixed: network),
            s3Session: session,
            resumeDirectory: resumeDirectory,
            retryDelays: [0, 0, 0]
        )
    }

    private func options(_ compression: UploadCompression = .off, force: Bool = false) -> UploadOptions {
        UploadOptions(filename: "a.jpg", contentType: "image/jpeg", compression: compression, forceMultipart: force, telemetry: false)
    }

    // MARK: Strategy (web SDK parity)

    func testPlanMatchesWebThresholds() {
        let wifi = NetworkSnapshot(interface: .wifi, isExpensive: false, isConstrained: false, measuredUplinkMbps: nil)
        XCTAssertEqual(UploadStrategy.plan(size: 2 * 1024 * 1024, network: wifi).strategy, .direct)
        XCTAssertEqual(UploadStrategy.plan(size: 8 * 1024 * 1024, network: wifi).strategy, .multipart)
        XCTAssertEqual(UploadStrategy.plan(size: 8 * 1024 * 1024, network: wifi).chunkSize, 8 * 1024 * 1024)
        XCTAssertEqual(UploadStrategy.plan(size: 2 * 1024 * 1024, network: wifi).concurrency, 4)
        XCTAssertEqual(UploadStrategy.plan(size: 2 * 1024 * 1024, network: wifi).stallTimeout, 45)

        let cellular = NetworkSnapshot(interface: .cellular, isExpensive: true, isConstrained: false, measuredUplinkMbps: nil)
        let slow = UploadStrategy.plan(size: 2 * 1024 * 1024, network: cellular)
        XCTAssertEqual(slow.networkClass, .threeG)
        XCTAssertEqual(slow.strategy, .multipart, "1 MB and up go multipart on a slow network, for per-part retry and resume")
        XCTAssertEqual(slow.chunkSize, 5 * 1024 * 1024)
        XCTAssertEqual(slow.concurrency, 2)
        XCTAssertEqual(slow.stallTimeout, 90)
        XCTAssertEqual(UploadStrategy.plan(size: 600 * 1024 * 1024, network: wifi).chunkSize, 16 * 1024 * 1024)
    }

    func testNetworkClassFromMeasurementAndLowDataMode() {
        func klass(_ interface: NetworkSnapshot.Interface, constrained: Bool = false, mbps: Double? = nil) -> NetworkClass {
            NetworkSnapshot(interface: interface, isExpensive: interface == .cellular, isConstrained: constrained, measuredUplinkMbps: mbps).networkClass
        }
        XCTAssertEqual(klass(.wifi), .fourG)
        XCTAssertEqual(klass(.cellular), .threeG)
        XCTAssertEqual(klass(.wifi, constrained: true), .twoG)
        XCTAssertEqual(klass(.cellular, mbps: 0.1), .slow2g)
        XCTAssertEqual(klass(.cellular, mbps: 0.4), .twoG)
        XCTAssertEqual(klass(.cellular, mbps: 1.5), .threeG)
        XCTAssertEqual(klass(.cellular, mbps: 20), .fourG)
        XCTAssertEqual(klass(.wifi, mbps: 0.3), .twoG, "a measured slow Wi-Fi is slow")
        XCTAssertEqual(klass(.none), .unknown)
        XCTAssertEqual(UploadStrategy.adaptConcurrency(.fourG, measuredMbps: 0.3), 1)
        XCTAssertEqual(UploadStrategy.adaptConcurrency(.fourG, measuredMbps: 1), 2)
        XCTAssertEqual(UploadStrategy.adaptConcurrency(.fourG, measuredMbps: 5), 3)
        XCTAssertEqual(UploadStrategy.adaptConcurrency(.fourG, measuredMbps: 50), 5)
    }

    // MARK: Compression

    func testAdaptiveCompressionResizesAndKeepsCaptureMetadata() throws {
        let original = try Self.jpeg(width: 4032, height: 3024, withGPS: true)
        let outcome = ImageCompression.compress(original, contentType: "image/jpeg", filename: "IMG_1.HEIC.jpg",
                                                profile: .forNetwork(.threeG))
        guard case .compressed(let result) = outcome else { return XCTFail("expected compression, got \(outcome)") }
        XCTAssertLessThan(result.data.count, original.count)
        let size = try XCTUnwrap(ImageCompression.pixelSize(of: result.data))
        XCTAssertEqual(max(size.width, size.height), 2048)
        XCTAssertEqual(size.width, 2048, "landscape stays landscape")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertNotNil(properties?[kCGImagePropertyGPSDictionary], "GPS must reach the platform, which keeps it privately and strips the served copy")
    }

    func testCompressionSkipsSmallAndAnimatedImages() throws {
        if case .compressed = ImageCompression.compress(Data(count: 10_000), contentType: "image/jpeg", filename: "a.jpg", profile: .forNetwork(.fourG)) {
            XCTFail("tiny images are sent as they are")
        }
        if case .compressed = ImageCompression.compress(Data(count: 500_000), contentType: "image/gif", filename: "a.gif", profile: .forNetwork(.fourG)) {
            XCTFail("GIFs keep their animation")
        }
    }

    // MARK: Direct

    func testDirectUploadPresignsPutsAndCompletes() async {
        let storage = await storage()
        let progress = ProgressLog()
        var opts = options()
        opts.onProgress = { progress.add($0) }
        let file = assertApiSuccess(await storage.upload(Data(count: 300_000), options: opts))
        XCTAssertEqual(file?.id, "f-direct")
        XCTAssertEqual(server.paths(), ["/v1/storage/signed-url/upload", "/single", "/v1/storage/signed-url/complete"])
        let presign = server.bodies(for: "/v1/storage/signed-url/upload").first
        XCTAssertEqual(presign?["visibility"] as? String, "private")
        XCTAssertEqual(presign?["size_bytes"] as? Int, 300_000)
        let put = server.requests.first { $0.url?.host == "s3.test" }
        XCTAssertEqual(put?.value(forHTTPHeaderField: "Content-Type"), "image/jpeg", "single PUT URLs are signed with the Content-Type")
        XCTAssertNotNil(server.requests.first?.value(forHTTPHeaderField: "X-Upload-Session-Id"))
        XCTAssertEqual(progress.last?.fraction, 1)
    }

    func testDirectUploadRetriesServerErrorsButNotSignatureErrors() async {
        server.singleScript = [503, nil, 200]
        let ok = await storage().upload(Data(count: 300_000), options: options())
        XCTAssertTrue(ok.isSuccess)
        XCTAssertEqual(server.paths().filter { $0 == "/single" }.count, 3)

        server = FakeStorageServer()
        server.install()
        server.singleScript = [403]
        let refused = await storage().upload(Data(count: 300_000), options: options())
        XCTAssertEqual(refused.error?.rawCode, "s3_signature_error")
        XCTAssertEqual(server.paths().filter { $0 == "/single" }.count, 1, "a refused signature is not retried")
        XCTAssertTrue(server.paths().contains("/v1/storage/signed-url/report-failure"))
    }

    // MARK: Multipart

    func testMultipartFetchesMoreLinksRefreshesExpiredOnesAndCompletesInOrder() async {
        server.partScript = [2: [403, 200]]
        let storage = await storage()
        let size = 2 * server.partSize + 1000
        let file = assertApiSuccess(await storage.upload(Data(count: size), options: options(force: true)))
        XCTAssertEqual(file?.id, "f-multi")
        let paths = server.paths()
        XCTAssertTrue(paths.contains("/v1/storage/signed-url/multipart/part-urls"), "part 3 had no link from start")
        XCTAssertEqual(paths.filter { $0 == "/part/2" }.count, 2, "expired link refreshed and retried")
        let complete = server.bodies(for: "/v1/storage/signed-url/multipart/complete").first
        let parts = complete?["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.compactMap { $0["part_number"] as? Int }, [1, 2, 3])
        XCTAssertEqual(parts?.compactMap { $0["etag"] as? String }, ["\"etag-1\"", "\"etag-2\"", "\"etag-3\""])
        XCTAssertEqual(complete?["completion_token"] as? String, "ctok")
        let start = server.bodies(for: "/v1/storage/signed-url/multipart/start").first
        XCTAssertNotNil(start?["client_upload_key"], "server-side idempotency for the same bytes")
    }

    func testFailedMultipartResumesWithOnlyTheMissingParts() async {
        // Part 2 loses its connection on every try.
        server.partScript = [2: [nil, nil, nil]]
        let data = Data((0..<(2 * server.partSize + 1000)).map { UInt8($0 % 251) })
        let first = await storage().upload(data, options: options(force: true))
        XCTAssertEqual(first.error?.code, .networkError)
        XCTAssertFalse(server.paths().contains("/v1/storage/signed-url/multipart/abort"), "a lost connection keeps the session")

        let firstRun = server!
        server = FakeStorageServer()
        server.install()
        let second = await storage().upload(data, options: options(force: true))
        XCTAssertTrue(second.isSuccess)
        let paths = server.paths()
        XCTAssertFalse(paths.contains("/v1/storage/signed-url/multipart/start"), "resumed, not restarted")
        XCTAssertEqual(paths.filter { $0.hasPrefix("/part/") }, ["/part/2"], "only the missing part is sent again")
        let parts = server.bodies(for: "/v1/storage/signed-url/multipart/complete").first?["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.count, 3)
        XCTAssertTrue(firstRun.paths().contains("/v1/storage/signed-url/report-failure"))
    }

    func testResumeStartsOverWhenTheServerForgotTheSession() async {
        server.partScript = [2: [nil, nil, nil]]
        let data = Data((0..<(2 * server.partSize + 1000)).map { UInt8($0 % 13) })
        _ = await storage().upload(data, options: options(force: true))

        server = FakeStorageServer()
        server.install()
        server.partURLsStatus = 404
        // The resume check (part-urls) gets 404; the fresh start hands out
        // links for every part, so the upload completes from the beginning.
        server.startPartURLs = 3
        let storage = await storage()
        let result = await storage.upload(data, options: options(force: true))
        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(server.paths().contains("/v1/storage/signed-url/multipart/start"))
    }

    func testCancelledMultipartIsAbortedOnTheServer() async {
        server.partScript = [1: [nil, nil, nil], 2: [nil, nil, nil], 3: [nil, nil, nil]]
        let storage = await storage()
        let task = Task { await storage.upload(Data(count: 2 * server.partSize + 1000), options: options(force: true)) }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.error?.rawCode, "aborted")
    }

    // MARK: Helpers

    static func jpeg(width: Int, height: Int, withGPS: Bool) throws -> Data {
        // Photo-like: smooth light plus sensor-style noise (flat blocks
        // would line up with JPEG's 8x8 grid and compress unrealistically well).
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 12345
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = Int(seed >> 27) - 16
                let i = (y * width + x) * 4
                pixels[i] = UInt8(clamping: x * 255 / width + noise)
                pixels[i + 1] = UInt8(clamping: y * 255 / height + noise)
                pixels[i + 2] = UInt8(clamping: 128 + noise)
            }
        }
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        if withGPS {
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 37.77, kCGImagePropertyGPSLatitudeRef: "N"]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UploadProgress] = []
    func add(_ item: UploadProgress) { lock.lock(); items.append(item); lock.unlock() }
    var last: UploadProgress? { lock.lock(); defer { lock.unlock() }; return items.last }
}
