#if os(iOS)
import AVFoundation
import MapKit
import ImageIO
import UIKit
import XCTest
@testable import ScaleMuleLocation
@testable import ScaleMuleMediaEditing
import ScaleMuleSocial

final class LocationKitTests: XCTestCase {
    private let museum = SharedLocation(precision: .place, latitude: 37.7857, longitude: -122.4011, name: "SFMOMA", placeId: "I6380")
    private let oakland = SharedLocation(precision: .city, latitude: 37.804, longitude: -122.271, name: "Oakland", locality: "Oakland")
    private let spot = SharedLocation(precision: .exact, latitude: 37.8044, longitude: -122.2712, name: "Oakland")

    func testChoicesDefaultToTheCityAndFollowTheAppsSettings() {
        let choices = LocationChoices(places: [museum], city: oakland, cityIsNearest: false, exact: spot)
        XCTAssertEqual(choices.available(.standard), [.place, .city, .exact, .none])
        XCTAssertEqual(choices.defaultKind(.standard), .city)
        XCTAssertEqual(choices.label(for: .place), "SFMOMA")
        XCTAssertEqual(choices.label(for: .city), "Oakland")
        let noExact = LocationSettings(allowedPrecisions: [.place, .city], presenceRequired: true, defaultPrecision: .city)
        XCTAssertEqual(choices.available(noExact), [.place, .city, .none])
        let placesOnly = LocationSettings(allowedPrecisions: [.place], presenceRequired: true, defaultPrecision: .place)
        XCTAssertEqual(choices.defaultKind(placesOnly), .place)
        // No city found: the default is no location, never the venue nearby.
        let noCity = LocationChoices(places: [museum], city: nil, cityIsNearest: false, exact: spot)
        XCTAssertEqual(noCity.defaultKind(.standard), .none)
        let nothing = LocationSettings(allowedPrecisions: [], presenceRequired: true, defaultPrecision: .city)
        XCTAssertEqual(choices.available(nothing), [.none])
        XCTAssertEqual(choices.defaultKind(nothing), .none)
        // Outside a city: the nearest one; nowhere near one: an area.
        let napa = SharedLocation(precision: .city, latitude: 38.297, longitude: -122.286, name: "near Napa", locality: "Napa")
        XCTAssertEqual(LocationChoices(places: [], city: napa, cityIsNearest: true, exact: spot).label(for: .city), "near Napa")
        let county = SharedLocation(precision: .area, latitude: 39.1, longitude: -120.9, name: "Placer County")
        let rural = LocationChoices(places: [], city: county, cityIsNearest: false, exact: spot)
        XCTAssertEqual(rural.label(for: .city), "near Placer County")
        XCTAssertEqual(rural.available(.standard), [.city, .exact, .none])
    }

    @MainActor
    func testRadiusLabelsFollowTheRegion() {
        XCTAssertEqual(NearbyFeed.radiusLabel(5, locale: Locale(identifier: "en_US")), "Within 3 mi")
        XCTAssertEqual(NearbyFeed.radiusLabel(160, locale: Locale(identifier: "en_US")), "Within 100 mi")
        XCTAssertEqual(NearbyFeed.radiusLabel(25, locale: Locale(identifier: "de_DE")), "Within 25 km")
        let us = NearbyFeed.radiusChoicesKm(locale: Locale(identifier: "en_US"))
        XCTAssertEqual(us.map { NearbyFeed.radiusLabel($0, locale: Locale(identifier: "en_US")) },
                       ["Within 3 mi", "Within 15 mi", "Within 50 mi", "Within 100 mi"])
        XCTAssertTrue(us.allSatisfy { $0 <= 160 }, "never past what Social allows")
        XCTAssertEqual(NearbyFeed.radiusChoicesKm(locale: Locale(identifier: "fr_FR")), [5, 25, 80, 160])
    }

    func testVenueCategoriesLeaveOutSensitivePlaces() {
        let categories = Set(PlaceResolver.venueCategories)
        for sensitive: MKPointOfInterestCategory in [.school, .university, .hospital, .hotel, .campground, .fitnessCenter, .police, .pharmacy] {
            XCTAssertFalse(categories.contains(sensitive), "\(sensitive.rawValue)")
        }
        XCTAssertTrue(categories.contains(.museum))
    }

    func testTrustedLocationRefusesSimulatedFixes() {
        XCTAssertTrue(LocationAccess.isTrusted(CLLocation(latitude: 37.8, longitude: -122.27)))
        if #available(iOS 15.0, *) {
            let simulated = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 37.8, longitude: -122.27),
                altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, courseAccuracy: 0,
                speed: 0, speedAccuracy: 0, timestamp: Date(),
                sourceInfo: CLLocationSourceInformation(softwareSimulationState: true, andExternalAccessoryState: false)
            )
            XCTAssertFalse(LocationAccess.isTrusted(simulated))
        }
    }

    private func noiseJPEG() -> Data {
        let size = CGSize(width: 640, height: 480)
        let image = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { context in
            for y in stride(from: 0, to: 480, by: 8) {
                for x in stride(from: 0, to: 640, by: 8) {
                    UIColor(hue: CGFloat((x * 7 + y * 13) % 360) / 360, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 8, height: 8))
                }
            }
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    func testCaptureLocationGoesIntoTheJPEGWithoutReencoding() throws {
        let original = noiseJPEG()
        XCTAssertNil(CaptureMetadata.location(inImage: original), "UIImage JPEGs carry no GPS")
        let taken = Date(timeIntervalSince1970: 1_795_000_000)
        for (lat, lon) in [(37.774_929, -122.419_416), (-33.8688, 151.2093)] {
            let tagged = CaptureMetadata.jpeg(original, adding: CaptureLocation(latitude: lat, longitude: lon, altitude: 12, horizontalAccuracy: 5, takenAt: taken))
            let read = try XCTUnwrap(CaptureMetadata.location(inImage: tagged))
            XCTAssertEqual(read.latitude, lat, accuracy: 1e-5)
            XCTAssertEqual(read.longitude, lon, accuracy: 1e-5)
            XCTAssertEqual(read.altitude ?? 0, 12, accuracy: 0.01)
            // Same picture: same size, and the compressed image data is copied.
            let source = try XCTUnwrap(CGImageSourceCreateWithData(tagged as CFData, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 640)
            XCTAssertLessThan(abs(tagged.count - original.count), 4_096, "metadata only, not a re-encode")
        }
    }

    private func clip() throws -> URL {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "portrait-1", withExtension: "mov", subdirectory: "Fixtures"))
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("loc-\(UUID().uuidString).mov")
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    private func locationTags(_ url: URL) async throws -> [String] {
        let asset = AVURLAsset(url: url)
        var values: [String] = []
        for format in try await asset.load(.availableMetadataFormats) {
            for item in try await asset.loadMetadata(for: format) {
                if let value = try? await item.load(.stringValue) { values.append(value) }
            }
        }
        return values
    }

    func testVideoExportCarriesTheCaptureLocationOnlyWhenGiven() async throws {
        let capture = CaptureLocation(latitude: 37.7749, longitude: -122.4194, altitude: 10)
        let tagged = try await VideoComposer.export(VideoEdit(clips: [try clip()]), location: capture)
        let tags = try await locationTags(tagged.file)
        XCTAssertTrue(tags.contains { $0.hasPrefix("+37.7749-122.4194") }, "\(tags)")
        let kept = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/location-export.mp4")
        try? FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: kept)
        try? FileManager.default.copyItem(at: tagged.file, to: kept)
        print("LOCATION-EXPORT \(kept.path)")
        let read = await CaptureMetadata.location(inVideo: tagged.file)
        XCTAssertEqual(read?.latitude ?? 0, 37.7749, accuracy: 1e-4)
        XCTAssertEqual(read?.longitude ?? 0, -122.4194, accuracy: 1e-4)
        XCTAssertEqual(CaptureMetadata.parseISO6709("-33.8688+151.2093/")?.longitude, 151.2093)
        let withCRS = CaptureMetadata.parseISO6709("+27.5916+086.5640+8850CRSWGS_84/")
        XCTAssertEqual(withCRS?.altitude, 8850)
        XCTAssertNil(CaptureMetadata.parseISO6709("nonsense"))
        let plain = try await VideoComposer.export(VideoEdit(clips: [try clip()]))
        let none = await CaptureMetadata.location(inVideo: plain.file)
        XCTAssertNil(none)
        let plainTags = try await locationTags(plain.file)
        XCTAssertFalse(plainTags.contains { $0.contains("+37.") }, "\(plainTags)")
    }
}
#endif
