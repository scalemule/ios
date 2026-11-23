import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleAuth
@testable import ScaleMuleStorage
@testable import ScaleMulePhotos
@testable import ScaleMuleProfiles

final class ProfilePhotoServiceTests: XCTestCase {
    static let appId = "019b247f-00c7-7443-a366-49435cd11a2b"
    static let newPhotoId = "01a20787-f585-77fc-9732-476c8f8db99e"
    static let oldPhotoId = "01a20700-0000-7000-8000-000000000001"
    static var avatarURL: String { "https://cdn-public.scalemule.com/\(appId)/anonymous/photos/\(newPhotoId)/w256_h256_cover_q85_jpeg.jpg" }
    static var oldAvatarURL: String { "https://cdn-public.scalemule.com/\(appId)/anonymous/photos/\(oldPhotoId)/w256_h256_cover_q85_jpeg.jpg" }

    static let photoJSON = """
    {"id": "\(newPhotoId)", "filename": "profile.jpg", "mime_type": "image/jpeg", "file_size": 20000,
     "width": 1024, "height": 512, "created_at": "2026-11-23T18:00:00Z",
     "original_url": "https://cdn-public.scalemule.com/\(appId)/anonymous/photos/\(newPhotoId)/original.jpeg"}
    """

    static func userJSON(avatar: String?) -> String {
        let value = avatar.map { "\"\($0)\"" } ?? "null"
        return TestFixtures.userJSON.replacingOccurrences(of: "\"avatar_url\": null", with: "\"avatar_url\": \(value)")
    }

    /// Upload telemetry (Storage reports to logs and analytics) is not part of the flow.
    static func telemetry(_ url: URL) -> (HTTPURLResponse, Data)? {
        guard url.path.hasPrefix("/v1/logger") || url.path.hasPrefix("/v1/analytics") else { return nil }
        return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{}}"#)
    }

    private func makeService(previousAvatar: String? = nil) async -> (ProfilePhotoService, ScaleMuleApp) {
        let (app, session) = createTestClient()
        try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600)))
        let data = Self.userJSON(avatar: previousAvatar).data(using: .utf8)!
        let user = try! JSONDecoder().decode(AuthUser.self, from: data)
        await app.authState.transition(to: .authenticated(user))
        let storage = StorageService(
            client: app.client,
            conditions: NetworkConditions(fixed: NetworkSnapshot(interface: .wifi, isExpensive: false, isConstrained: false, measuredUplinkMbps: nil)),
            s3Session: session,
            resumeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("sm-profiles-\(UUID().uuidString)"),
            retryDelays: [0, 0, 0]
        )
        let photos = PhotosService(client: app.client, storage: storage)
        photos.publicRenditionPollDelays = [0, 0, 0]
        return (ProfilePhotoService(auth: AuthService(app: app), photos: photos, app: app), app)
    }

    /// A JPEG of `width` x `height` carrying GPS and camera metadata, stored
    /// with an orientation tag that turns it on its side.
    static func sampleJPEG(width: Int = 2000, height: Int = 1000, orientation: Int = 1) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.7749, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.4194, kCGImagePropertyGPSLongitudeRef: "W",
            ],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam", kCGImagePropertyTIFFModel: "Model 1"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    // MARK: - Image

    func testPrepareResizesMakesUprightAndStripsMetadata() throws {
        // Orientation 6 = stored sideways; upright it is 1000 wide, 2000 high.
        let prepared = try XCTUnwrap(ProfilePhotoImage.prepare(Self.sampleJPEG(orientation: 6)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 512)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 1024)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary], "no GPS in a public picture")
        XCTAssertNil((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake])
        XCTAssertTrue([nil, 1].contains(properties[kCGImagePropertyOrientation] as? Int), "pixels are upright")
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
    }

    func testPrepareKeepsSmallPicturesAtTheirSize() throws {
        let prepared = try XCTUnwrap(ProfilePhotoImage.prepare(Self.sampleJPEG(width: 300, height: 200)))
        XCTAssertEqual(ImageCompression.pixelSize(of: prepared)?.width, 300)
        XCTAssertEqual(ImageCompression.pixelSize(of: prepared)?.height, 200)
    }

    func testPrepareRefusesNonImages() {
        XCTAssertNil(ProfilePhotoImage.prepare(Data("not a picture".utf8)))
    }

    // MARK: - Set

    func testSetUploadsPublicRegistersTakesTheCDNLinkAndUpdatesTheProfile() async throws {
        let (service, app) = await makeService(previousAvatar: Self.oldAvatarURL)
        let input = Self.sampleJPEG()
        var calls: [String] = []
        var uploadedSize: Int?
        var manifestLooks = 0
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if let ack = Self.telemetry(url) { return ack }
            calls.append("\(request.httpMethod!) \(url.path)")
            if url.host == "s3.test" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func q(_ name: String) -> String? { query.first { $0.name == name }?.value }
            switch url.path {
            case "/v1/storage/signed-url/upload":
                let body = self.bodyJSON(request)
                XCTAssertEqual(body?["visibility"] as? String, "anonymous_visible")
                XCTAssertEqual(body?["content_type"] as? String, "image/jpeg")
                uploadedSize = body?["size_bytes"] as? Int
                return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{"file_id":"file-1","upload_url":"https://s3.test/x","completion_token":"t"}}"#)
            case "/v1/storage/signed-url/complete":
                return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{"file_id":"file-1","filename":"profile.jpg","size_bytes":6,"content_type":"image/jpeg","visibility":"anonymous_visible"}}"#)
            case "/v1/photos/register":
                XCTAssertEqual(self.bodyJSON(request)?["file_id"] as? String, "file-1")
                return TestFixtures.mockResponse(statusCode: 201, json: "{\"success\": true, \"data\": \(Self.photoJSON)}")
            case "/v1/photos/public/\(Self.newPhotoId)/manifest":
                XCTAssertEqual(q("rendition"), "w256_h256_cover_q85_jpeg")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "public route, no session")
                manifestLooks += 1
                if manifestLooks == 1 {
                    return TestFixtures.mockResponse(statusCode: 200, json: "{\"success\":true,\"data\":{\"photo_id\":\"\(Self.newPhotoId)\",\"ready\":false}}")
                }
                return TestFixtures.mockResponse(statusCode: 200, json: "{\"success\":true,\"data\":{\"photo_id\":\"\(Self.newPhotoId)\",\"ready\":true,\"url\":\"\(Self.avatarURL)\",\"width\":256,\"height\":256}}")
            case "/v1/photos/public/\(Self.newPhotoId)/transform":
                XCTAssertEqual(q("width"), "256")
                XCTAssertEqual(q("height"), "256")
                XCTAssertEqual(q("fit"), "cover")
                XCTAssertEqual(q("quality"), "85")
                XCTAssertEqual(q("format"), "jpeg")
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/jpeg"])!, Data([0xFF, 0xD8]))
            case "/v1/auth/profile":
                XCTAssertEqual(request.httpMethod, "PATCH")
                let body = self.bodyJSON(request)
                XCTAssertEqual(body?.count, 1, "only the photo changes")
                XCTAssertEqual(body?["avatar_url"] as? String, Self.avatarURL)
                return TestFixtures.envelopedResponse(json: Self.userJSON(avatar: Self.avatarURL))
            case "/v1/photos/\(Self.oldPhotoId)":
                XCTAssertEqual(request.httpMethod, "DELETE")
                return (HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            default:
                XCTFail("Unexpected \(url.path)")
                return TestFixtures.mockResponse(statusCode: 404, json: #"{"success":false}"#)
            }
        }

        let user = assertApiSuccess(await service.setProfilePhoto(input))
        XCTAssertEqual(user?.avatarUrl, Self.avatarURL)
        XCTAssertEqual(user?.avatarURL?.absoluteString, Self.avatarURL)
        let size = try XCTUnwrap(uploadedSize)
        XCTAssertLessThan(size, input.count, "the prepared picture is sent, not the input")
        XCTAssertEqual(calls.last, "DELETE /v1/photos/\(Self.oldPhotoId)", "the previous profile photo goes last")
        XCTAssertTrue(calls.contains("GET /v1/photos/public/\(Self.newPhotoId)/transform"))
        if case .authenticated(let current) = await app.authState.state {
            XCTAssertEqual(current.avatarUrl, Self.avatarURL)
        } else {
            XCTFail("still signed in with the new photo")
        }
    }

    func testReadySizeIsUsedWithoutMakingIt() async {
        let (service, _) = await makeService()
        var transformed = false
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if let ack = Self.telemetry(url) { return ack }
            if url.host == "s3.test" { return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data()) }
            switch url.path {
            case "/v1/storage/signed-url/upload":
                return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{"file_id":"file-1","upload_url":"https://s3.test/x","completion_token":"t"}}"#)
            case "/v1/storage/signed-url/complete":
                return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{"file_id":"file-1","filename":"profile.jpg","size_bytes":6,"content_type":"image/jpeg","visibility":"anonymous_visible"}}"#)
            case "/v1/photos/register":
                return TestFixtures.mockResponse(statusCode: 201, json: "{\"success\": true, \"data\": \(Self.photoJSON)}")
            case "/v1/photos/public/\(Self.newPhotoId)/manifest":
                return TestFixtures.mockResponse(statusCode: 200, json: "{\"success\":true,\"data\":{\"photo_id\":\"\(Self.newPhotoId)\",\"ready\":true,\"url\":\"\(Self.avatarURL)\"}}")
            case "/v1/photos/public/\(Self.newPhotoId)/transform":
                transformed = true
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            case "/v1/auth/profile":
                return TestFixtures.envelopedResponse(json: Self.userJSON(avatar: Self.avatarURL))
            default:
                XCTFail("Unexpected \(request.httpMethod!) \(url.path): no previous photo to delete")
                return TestFixtures.mockResponse(statusCode: 404, json: #"{"success":false}"#)
            }
        }
        let set = await service.setProfilePhoto(Self.sampleJPEG())
        XCTAssertNotNil(assertApiSuccess(set))
        XCTAssertFalse(transformed)
    }

    func testStorageDemotingVisibilityIsRefused() async {
        let (service, _) = await makeService()
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if let ack = Self.telemetry(url) { return ack }
            if url.host == "s3.test" { return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data()) }
            switch url.path {
            case "/v1/storage/signed-url/upload":
                return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{"file_id":"file-1","upload_url":"https://s3.test/x","completion_token":"t"}}"#)
            case "/v1/storage/signed-url/complete":
                return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{"file_id":"file-1","filename":"profile.jpg","size_bytes":6,"content_type":"image/jpeg","visibility":"private"}}"#)
            default:
                XCTFail("Unexpected \(url.path)")
                return TestFixtures.mockResponse(statusCode: 404, json: #"{"success":false}"#)
            }
        }
        let error = assertApiFailure(await service.setProfilePhoto(Self.sampleJPEG()))
        XCTAssertEqual(error?.rawCode, "visibility_violation")
    }

    func testSizeNeverReadyFailsWithAFriendlyMessageAndKeepsTheProfile() async {
        let (service, _) = await makeService()
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if let ack = Self.telemetry(url) { return ack }
            if url.host == "s3.test" { return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data()) }
            switch url.path {
            case "/v1/storage/signed-url/upload":
                return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{"file_id":"file-1","upload_url":"https://s3.test/x","completion_token":"t"}}"#)
            case "/v1/storage/signed-url/complete":
                return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{"file_id":"file-1","filename":"profile.jpg","size_bytes":6,"content_type":"image/jpeg","visibility":"anonymous_visible"}}"#)
            case "/v1/photos/register":
                return TestFixtures.mockResponse(statusCode: 201, json: "{\"success\": true, \"data\": \(Self.photoJSON)}")
            case "/v1/photos/public/\(Self.newPhotoId)/manifest":
                // A link that is not HTTPS is never used.
                return TestFixtures.mockResponse(statusCode: 200, json: "{\"success\":true,\"data\":{\"photo_id\":\"\(Self.newPhotoId)\",\"ready\":true,\"url\":\"http://cdn.test/x.jpg\"}}")
            case "/v1/photos/public/\(Self.newPhotoId)/transform":
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            default:
                XCTFail("Unexpected \(request.httpMethod!) \(url.path)")
                return TestFixtures.mockResponse(statusCode: 404, json: #"{"success":false}"#)
            }
        }
        let error = assertApiFailure(await service.setProfilePhoto(Self.sampleJPEG()))
        XCTAssertEqual(error?.rawCode, PhotosService.renditionPendingCode)
        XCTAssertEqual(error?.userFacingMessage, "Your photo is still being prepared. Try again in a moment.")
    }

    func testProfileUpdateFailureDeletesTheNewPhoto() async {
        let (service, _) = await makeService(previousAvatar: Self.oldAvatarURL)
        var deleted: [String] = []
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if let ack = Self.telemetry(url) { return ack }
            if url.host == "s3.test" { return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data()) }
            switch url.path {
            case "/v1/storage/signed-url/upload":
                return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{"file_id":"file-1","upload_url":"https://s3.test/x","completion_token":"t"}}"#)
            case "/v1/storage/signed-url/complete":
                return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{"file_id":"file-1","filename":"profile.jpg","size_bytes":6,"content_type":"image/jpeg","visibility":"anonymous_visible"}}"#)
            case "/v1/photos/register":
                return TestFixtures.mockResponse(statusCode: 201, json: "{\"success\": true, \"data\": \(Self.photoJSON)}")
            case "/v1/photos/public/\(Self.newPhotoId)/manifest":
                return TestFixtures.mockResponse(statusCode: 200, json: "{\"success\":true,\"data\":{\"photo_id\":\"\(Self.newPhotoId)\",\"ready\":true,\"url\":\"\(Self.avatarURL)\"}}")
            case "/v1/auth/profile":
                return TestFixtures.mockResponse(statusCode: 400, json: #"{"success":false,"error":{"code":"INVALID_INPUT","message":"Not allowed"}}"#)
            default:
                if request.httpMethod == "DELETE" { deleted.append(url.lastPathComponent) }
                return (HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            }
        }
        let set = await service.setProfilePhoto(Self.sampleJPEG())
        XCTAssertNotNil(assertApiFailure(set))
        XCTAssertEqual(deleted, [Self.newPhotoId], "the new photo goes; the one on the profile stays")
    }

    func testUnreadablePictureSendsNothing() async {
        let (service, _) = await makeService()
        MockURLProtocol.requestHandler = { request in
            if let ack = Self.telemetry(request.url!) { return ack }
            XCTFail("No request expected: \(request.url!.path)")
            return TestFixtures.mockResponse(statusCode: 500, json: "{}")
        }
        let error = assertApiFailure(await service.setProfilePhoto(Data("nope".utf8)), code: .validationError)
        XCTAssertEqual(error?.userFacingMessage, "This picture could not be read. Choose another one.")
    }

    // MARK: - Remove

    func testRemoveEmptiesAvatarAndDeletesThePhoto() async {
        let (service, _) = await makeService(previousAvatar: Self.oldAvatarURL)
        var calls: [String] = []
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if let ack = Self.telemetry(url) { return ack }
            calls.append("\(request.httpMethod!) \(url.path)")
            if url.path == "/v1/auth/profile" {
                let body = self.bodyJSON(request)
                XCTAssertEqual(body?.count, 1)
                XCTAssertEqual(body?["avatar_url"] as? String, "", "Auth clears with an empty string; null changes nothing")
                return TestFixtures.envelopedResponse(json: Self.userJSON(avatar: ""))
            }
            return (HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        let user = assertApiSuccess(await service.removeProfilePhoto())
        XCTAssertEqual(user?.avatarUrl, "")
        XCTAssertNil(user?.avatarURL)
        XCTAssertEqual(calls, ["PATCH /v1/auth/profile", "DELETE /v1/photos/\(Self.oldPhotoId)"])
    }

    func testRemoveLeavesForeignPicturesAlone() async {
        let (service, _) = await makeService(previousAvatar: "https://lh3.googleusercontent.com/a/abc=s96-c")
        var calls: [String] = []
        MockURLProtocol.requestHandler = { request in
            if let ack = Self.telemetry(request.url!) { return ack }
            calls.append("\(request.httpMethod!) \(request.url!.path)")
            return TestFixtures.envelopedResponse(json: Self.userJSON(avatar: ""))
        }
        let removed = await service.removeProfilePhoto()
        XCTAssertNotNil(assertApiSuccess(removed))
        XCTAssertEqual(calls, ["PATCH /v1/auth/profile"])
    }

    // MARK: - Links

    func testPhotoIdFromAvatarURL() {
        XCTAssertEqual(ProfilePhotoService.photoId(fromAvatarURL: URL(string: Self.avatarURL)), Self.newPhotoId)
        XCTAssertNil(ProfilePhotoService.photoId(fromAvatarURL: URL(string: "https://example.com/a.jpg")))
        XCTAssertNil(ProfilePhotoService.photoId(fromAvatarURL: URL(string: "http://cdn-public.scalemule.com/\(Self.appId)/anonymous/photos/\(Self.newPhotoId)/x.jpg")))
        XCTAssertNil(ProfilePhotoService.photoId(fromAvatarURL: URL(string: "https://cdn-public.scalemule.com/\(Self.appId)/anonymous/photos/not-a-uuid/x.jpg")))
        XCTAssertNil(ProfilePhotoService.photoId(fromAvatarURL: nil))
    }

    func testRenditionKeyMatchesPhotos() {
        XCTAssertEqual(PhotosService.renditionKey(width: 256, height: 256, fit: .cover), "w256_h256_cover_q85_jpeg")
        XCTAssertEqual(PhotosService.renditionKey(width: 64, height: 64, fit: .cover, quality: 200, format: .webp), "w64_h64_cover_q100_webp")
    }

    func testAvatarURLOnlyForHTTPS() {
        func user(_ avatar: String?) -> AuthUser { AuthUser(id: "u", avatarUrl: avatar) }
        XCTAssertNil(user(nil).avatarURL)
        XCTAssertNil(user("").avatarURL)
        XCTAssertNil(user("   ").avatarURL)
        XCTAssertNil(user("javascript:alert(1)").avatarURL)
        XCTAssertNil(user("http://example.com/a.jpg").avatarURL)
        XCTAssertEqual(user(Self.avatarURL).avatarURL?.absoluteString, Self.avatarURL)
    }
}
