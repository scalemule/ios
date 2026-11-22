import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMulePhotos

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
        let (app, _) = createTestClient()
        try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600)))
        return PhotosService(app: app)
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

    func testUploadSendsMultipartFile() async {
        let photos = await signedIn()
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/photos/upload")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sess_123")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "pk_test_abc123")
            let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
            let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
            let sent = self.body(request)
            let text = String(decoding: sent, as: UTF8.self)
            XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"file\"; filename=\"shot.jpg\""))
            XCTAssertTrue(text.contains("Content-Type: image/jpeg"))
            XCTAssertNotNil(sent.range(of: jpeg))
            XCTAssertTrue(text.hasSuffix("--\(boundary)--\r\n"))
            return TestFixtures.mockResponse(statusCode: 201, json: "{\"success\": true, \"data\": \(Self.photoJSON)}")
        }

        let photo = assertApiSuccess(await photos.upload(jpeg, filename: "shot.jpg"))
        XCTAssertEqual(photo?.id, "019b0000-0000-7000-8000-0000000000ff")
        XCTAssertEqual(photo?.width, 1080)
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
