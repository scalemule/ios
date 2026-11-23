#if os(iOS)
import CoreLocation
import Foundation
import MapKit
import ScaleMuleSocial

/// What the person can share with a post.
public enum LocationChoiceKind: String, Sendable, CaseIterable, Codable {
    /// A public venue nearby: the venue's point.
    case place
    /// The city's centre (or the nearest city; a coarse area when there is none).
    case city
    /// The spot itself.
    case exact
    /// No location.
    case none
}

/// The ways one GPS fix can be shared. Only these public points ever leave
/// the phone; the fix itself does not.
public struct LocationChoices: Sendable, Equatable {
    /// Public venues within about 150 m, nearest first.
    public let places: [SharedLocation]
    /// The city, the nearest city (`cityIsNearest`), or a coarse area.
    public let city: SharedLocation?
    public let cityIsNearest: Bool
    /// The spot, to about 10 m.
    public let exact: SharedLocation

    public init(places: [SharedLocation], city: SharedLocation?, cityIsNearest: Bool, exact: SharedLocation) {
        self.places = places
        self.city = city
        self.cityIsNearest = cityIsNearest
        self.exact = exact
    }

    public func location(for kind: LocationChoiceKind, place index: Int = 0) -> SharedLocation? {
        switch kind {
        case .place: return places.indices.contains(index) ? places[index] : places.first
        case .city: return city
        case .exact: return exact
        case .none: return nil
        }
    }

    /// "SFMOMA", "Oakland", "near Napa", "Exact spot".
    public func label(for kind: LocationChoiceKind, place index: Int = 0) -> String? {
        switch kind {
        case .place: return location(for: .place, place: index)?.label
        case .city:
            guard let city, let name = city.label else { return nil }
            return cityIsNearest || city.precision == .area ? "near \(name)" : name
        case .exact: return "Exact spot"
        case .none: return nil
        }
    }

    /// The choices the app allows that this fix can make.
    public func available(_ settings: LocationSettings) -> [LocationChoiceKind] {
        LocationChoiceKind.allCases.filter { kind in
            switch kind {
            case .place: return !places.isEmpty && settings.allowedPrecisions.contains(.place)
            case .city: return city.map { settings.allowedPrecisions.contains($0.precision) } ?? false
            case .exact: return settings.allowedPrecisions.contains(.exact)
            case .none: return true
            }
        }
    }

    /// The app's default (city unless it says otherwise), never the exact
    /// spot unless the app made that its default.
    public func defaultKind(_ settings: LocationSettings) -> LocationChoiceKind {
        let available = available(settings)
        let preferred: LocationChoiceKind
        switch settings.defaultPrecision {
        case .place: preferred = .place
        case .city, .area: preferred = .city
        case .exact: preferred = .exact
        }
        for kind in [preferred, .city, .place] where available.contains(kind) { return kind }
        return .none
    }
}

/// Turns a GPS fix into the public points a post can share: nearby venues,
/// the city's centre or the nearest city, the spot. Uses Apple Maps on the
/// phone, worldwide; nothing is sent to ScaleMule.
public actor PlaceResolver {
    public static let shared = PlaceResolver()

    /// Venues people gather at in public. Never homes, schools, hospitals,
    /// hotels, gyms or places of worship, where a post would say too much.
    public static var venueCategories: [MKPointOfInterestCategory] {
        var categories: [MKPointOfInterestCategory] = [
            .amusementPark, .aquarium, .beach, .brewery, .cafe, .campground, .foodMarket,
            .library, .marina, .movieTheater, .museum, .nationalPark, .nightlife, .park,
            .restaurant, .stadium, .theater, .university, .winery, .zoo, .airport,
        ]
        if #available(iOS 18.0, *) {
            categories += [
                .castle, .conventionCenter, .fairground, .landmark, .musicVenue,
                .nationalMonument, .planetarium, .baseball, .basketball, .soccer, .tennis,
                .bowling, .skatePark, .distillery, .fortress,
            ]
        }
        return categories
    }

    private let geocoder = CLGeocoder()
    private var centres: [String: CLLocationCoordinate2D?] = [:]

    public init() {}

    public func choices(for location: CLLocation) async -> LocationChoices {
        let coordinate = location.coordinate
        let places = await venues(near: coordinate)
        let placemark = try? await geocoder.reverseGeocodeLocation(location).first
        let exactName = placemark?.locality ?? placemark?.subAdministrativeArea
        let exact = SharedLocation(
            precision: .exact,
            latitude: Self.round(coordinate.latitude, 4),
            longitude: Self.round(coordinate.longitude, 4),
            name: exactName,
            locality: placemark?.locality,
            region: placemark?.administrativeArea,
            countryCode: placemark?.isoCountryCode
        )
        let (city, nearest) = await city(for: coordinate, placemark: placemark)
        return LocationChoices(places: places, city: city, cityIsNearest: nearest, exact: exact)
    }

    // MARK: - Venues

    private func venues(near coordinate: CLLocationCoordinate2D) async -> [SharedLocation] {
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: 150)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: Self.venueCategories)
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return response.mapItems
            .compactMap { item -> (Double, SharedLocation)? in
                guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
                let point = item.placemark.coordinate
                let distance = here.distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
                let location = SharedLocation(
                    precision: .place,
                    latitude: Self.round(point.latitude, 4),
                    longitude: Self.round(point.longitude, 4),
                    name: String(name.prefix(120)),
                    locality: item.placemark.locality,
                    region: item.placemark.administrativeArea,
                    countryCode: item.placemark.isoCountryCode,
                    placeId: Self.placeId(item, name: name, point: point)
                )
                return (distance, location)
            }
            .sorted { $0.0 < $1.0 }
            .prefix(5)
            .map(\.1)
    }

    /// Apple's stable id for the venue (iOS 18); otherwise its name and point,
    /// which every phone at the venue resolves the same way.
    static func placeId(_ item: MKMapItem, name: String, point: CLLocationCoordinate2D) -> String {
        if #available(iOS 18.0, *), let identifier = item.identifier?.rawValue, !identifier.isEmpty {
            return String(identifier.prefix(190))
        }
        let key = "mk:\(name.lowercased())@\(String(format: "%.4f,%.4f", point.latitude, point.longitude))"
        return String(key.prefix(190))
    }

    // MARK: - City

    private func city(
        for coordinate: CLLocationCoordinate2D,
        placemark: CLPlacemark?
    ) async -> (SharedLocation?, Bool) {
        if let placemark, let locality = placemark.locality {
            return (await cityLocation(locality: locality, region: placemark.administrativeArea, country: placemark.isoCountryCode), false)
        }
        // Outside a city: the nearest town, found by its post office, library
        // or fire station (every town has one), and its own centre.
        if let town = await nearestTown(to: coordinate) {
            return (await cityLocation(locality: town.locality, region: town.region, country: town.country), true)
        }
        // Nowhere near a town: a coarse area named after the county or region.
        guard let name = placemark?.subAdministrativeArea ?? placemark?.administrativeArea else { return (nil, false) }
        return (SharedLocation(
            precision: .area,
            latitude: Self.round(coordinate.latitude, 1),
            longitude: Self.round(coordinate.longitude, 1),
            name: name,
            region: placemark?.administrativeArea,
            countryCode: placemark?.isoCountryCode
        ), false)
    }

    private func nearestTown(to coordinate: CLLocationCoordinate2D) async -> (locality: String, region: String?, country: String?)? {
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: 30_000)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.postOffice, .library, .fireStation, .police])
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let nearest = response.mapItems
            .filter { $0.placemark.locality != nil }
            .min { a, b in
                here.distance(from: CLLocation(latitude: a.placemark.coordinate.latitude, longitude: a.placemark.coordinate.longitude))
                    < here.distance(from: CLLocation(latitude: b.placemark.coordinate.latitude, longitude: b.placemark.coordinate.longitude))
            }
        guard let nearest, let locality = nearest.placemark.locality else { return nil }
        return (locality, nearest.placemark.administrativeArea, nearest.placemark.isoCountryCode)
    }

    /// The city's own centre, never a point derived from the person's fix.
    /// When Maps cannot place the city, a coarse area (about 11 km) instead.
    private func cityLocation(locality: String, region: String?, country: String?) async -> SharedLocation? {
        let query = [locality, region, country].compactMap { $0 }.joined(separator: ", ")
        let centre: CLLocationCoordinate2D?
        if let cached = centres[query] {
            centre = cached
        } else {
            centre = try? await geocoder.geocodeAddressString(query).first?.location?.coordinate
            centres[query] = centre
        }
        guard let centre else { return nil }
        return SharedLocation(
            precision: .city,
            latitude: Self.round(centre.latitude, 3),
            longitude: Self.round(centre.longitude, 3),
            name: locality,
            locality: locality,
            region: region,
            countryCode: country
        )
    }

    static func round(_ value: Double, _ places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }
}
#endif
