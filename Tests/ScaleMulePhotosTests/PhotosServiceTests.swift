import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMulePhotos
@testable import ScaleMuleStorage

final class PhotosServiceTests: XCTestCase {
    static let photoJSON = """
    {
        "id": "019b0000-0000-7000-8000-0000000000ff",
        "original_url": null,
        "filename": "shot.jpg",
        "mime_type": "image/jpeg",
        "file_size": 1234,
        "width": 1080,
        "height": 1440,
        "metadata": {},
        "created_at": "2026-11-21T18:00:00Z"
    }
    """

    private func signedIn() async -> PhotosService {
        let (app, session) = createTestClient()
        try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600)))
        let storage = StorageService(
            client: app.client,
            conditions: NetworkConditions(fixed: NetworkSnapshot(interface: .wifi, isExpensive: false, isConstrained: false, measuredUplinkMbps: nil)),
            s3Session: session,
            resumeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("sm-photos-\(UUID().uuidString)"),
            retryDelays: [0, 0, 0]
        )
        return PhotosService(client: app.client, storage: storage)
    }

    private func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    func testUploadGoesThroughStorageThenRegisters() async {
        let photos = await signedIn()
        var registerCalls = 0
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if url.host == "s3.test" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sess_123")
            switch url.path {
            case "/v1/storage/signed-url/upload":
                return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{"file_id":"file-1","upload_url":"https://s3.test/x","completion_token":"t"}}"#)
            case "/v1/storage/signed-url/complete":
                return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{"file_id":"file-1","filename":"shot.jpg","size_bytes":6,"content_type":"image/jpeg"}}"#)
            case "/v1/photos/register":
                registerCalls += 1
                XCTAssertEqual(self.bodyJSON(request)?["file_id"] as? String, "file-1")
                if registerCalls == 1 {
                    // Safety scan still running.
                    return TestFixtures.mockResponse(statusCode: 202, json: #"{"success":true,"data":{"status":"pending_scan"}}"#)
                }
                return TestFixtures.mockResponse(statusCode: 201, json: "{\"success\": true, \"data\": \(Self.photoJSON)}")
            default:
                return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{}}"#)
            }
        }

        let photo = assertApiSuccess(await photos.upload(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02]), filename: "shot.jpg"))
        XCTAssertEqual(photo?.id, "019b0000-0000-7000-8000-0000000000ff")
        XCTAssertEqual(photo?.width, 1080)
        XCTAssertEqual(registerCalls, 2, "pending_scan is asked again")
    }

    func testAttachOriginalUploadsUnchangedThenAttaches() async {
        let photos = await signedIn()
        let original = Data(repeating: 7, count: 300_000)
        var attachCalls = 0
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if url.host == "s3.test" {
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
            switch url.path {
            case "/v1/storage/signed-url/upload":
                let body = self.bodyJSON(request)
                XCTAssertEqual(body?["visibility"] as? String, "private")
                XCTAssertEqual(body?["size_bytes"] as? Int, 300_000, "the original is sent unchanged")
                return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{"file_id":"orig-1","upload_url":"https://s3.test/x","completion_token":"t"}}"#)
            case "/v1/storage/signed-url/complete":
                return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{"file_id":"orig-1","filename":"o.jpg","size_bytes":300000,"content_type":"image/jpeg","visibility":"private"}}"#)
            case "/v1/photos/p1/original":
                attachCalls += 1
                XCTAssertEqual(self.bodyJSON(request)?["file_id"] as? String, "orig-1")
                if attachCalls == 1 {
                    return TestFixtures.mockResponse(statusCode: 202, json: #"{"success":true,"data":{"status":"pending_scan"}}"#)
                }
                return TestFixtures.mockResponse(statusCode: 200, json: "{\"success\": true, \"data\": \(Self.photoJSON)}")
            default:
                return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{}}"#)
            }
        }
        let photo = assertApiSuccess(await photos.attachOriginal(photoId: "p1", original, filename: "o.jpg"))
        XCTAssertEqual(photo?.id, "019b0000-0000-7000-8000-0000000000ff")
        XCTAssertEqual(attachCalls, 2)
    }

    func testImageReturnsRawBytesAndSendsSize() async {
        let photos = await signedIn()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/photos/p1/transform")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            XCTAssertEqual(items.first { $0.name == "width" }?.value, "1080")
            XCTAssertEqual(items.first { $0.name == "fit" }?.value, "cover")
            XCTAssertNil(items.first { $0.name == "height" })
            XCTAssertTrue(request.value(forHTTPHeaderField: "Accept")?.hasPrefix("image/") ?? false)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
            return (response, bytes)
        }

        let data = assertApiSuccess(await photos.image(id: "p1", width: 1080, fit: .cover))
        XCTAssertEqual(data, bytes)
    }

    func testImageWhileScanPendingKeepsServerCode() async {
        let photos = await signedIn()
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 403, json: "{\"success\": false, \"error\": {\"code\": \"SCAN_PENDING\", \"message\": \"Photo not yet verified safe\"}}")
        }
        let error = assertApiFailure(await photos.image(id: "p1", width: 320))
        XCTAssertEqual(error?.rawCode, PhotosService.scanPendingCode)
        XCTAssertEqual(error?.statusCode, 403)
    }
}
