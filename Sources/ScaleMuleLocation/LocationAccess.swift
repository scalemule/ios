#if os(iOS)
import CoreLocation
import Foundation

/// The person's location for posting and for "around me": permission, and a
/// recent, accurate, real fix. A fix a simulator or a location-spoofing tool
/// made is never used (`isSimulated`).
///
/// Add `NSLocationWhenInUseUsageDescription` to the app's Info.plist.
@MainActor
public final class LocationAccess: NSObject, ObservableObject {
    public static let shared = LocationAccess()

    @Published public private(set) var authorization: CLAuthorizationStatus
    /// The latest real fix.
    @Published public private(set) var current: CLLocation?
    /// The latest fix was simulated, so nothing location-filtered is shown.
    @Published public private(set) var isSimulated = false

    private let manager = CLLocationManager()
    private var waiters: [UUID: (maxAge: TimeInterval, continuation: CheckedContinuation<CLLocation?, Never>)] = [:]
    private var watching = false

    public override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // Every fix while watching, so `current` stays fresh standing still.
        manager.distanceFilter = kCLDistanceFilterNone
    }

    /// Location is on for this app.
    public var isOn: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    /// The system prompt has not been shown yet.
    public var canAsk: Bool { authorization == .notDetermined }

    /// Shows the system prompt (once; afterwards only Settings can change it).
    public func requestPermission() {
        if canAsk { manager.requestWhenInUseAuthorization() }
    }

    /// Keep `current` up to date while location-filtered content is on screen.
    public func startWatching() {
        watching = true
        if isOn { manager.startUpdatingLocation() }
    }

    public func stopWatching() {
        watching = false
        // Stopping updates would cancel a pending one-off request.
        if waiters.isEmpty { manager.stopUpdatingLocation() }
    }

    /// A real fix no older than `maxAge` and within 1 km, or `nil` when location
    /// is off, simulated or does not arrive within `timeout`.
    public func freshLocation(maxAge: TimeInterval = 120, timeout: TimeInterval = 12) async -> CLLocation? {
        if let current, Self.isUsable(current, maxAge: maxAge) { return current }
        guard isOn else { return nil }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = (maxAge, continuation)
            manager.requestLocation()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.waiters.removeValue(forKey: id)?.continuation.resume(returning: nil)
                self?.stopIfIdle()
            }
        }
    }

    /// Not made by a simulator or a spoofing tool.
    public nonisolated static func isTrusted(_ location: CLLocation) -> Bool {
        if #available(iOS 15.0, *), let source = location.sourceInformation, source.isSimulatedBySoftware {
            return false
        }
        return true
    }

    nonisolated static func isUsable(_ location: CLLocation, maxAge: TimeInterval) -> Bool {
        isTrusted(location)
            && location.horizontalAccuracy >= 0
            && location.horizontalAccuracy <= 1_000
            && -location.timestamp.timeIntervalSinceNow <= maxAge
    }

    private func receive(_ location: CLLocation) {
        guard Self.isTrusted(location) else {
            isSimulated = true
            current = nil
            finishWaiters(nil)
            return
        }
        isSimulated = false
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 1_000 else { return }
        current = location
        // A cached old fix often comes first: each waiter takes only one
        // young enough for it and keeps waiting otherwise.
        for (id, waiter) in waiters where Self.isUsable(location, maxAge: waiter.maxAge) {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: location)
        }
        stopIfIdle()
    }

    private func finishWaiters(_ location: CLLocation?) {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending.values { waiter.continuation.resume(returning: location) }
        stopIfIdle()
    }

    private func stopIfIdle() {
        if !watching && waiters.isEmpty { manager.stopUpdatingLocation() }
    }

    private func authorizationChanged(_ status: CLAuthorizationStatus) {
        authorization = status
        if isOn {
            if watching { manager.startUpdatingLocation() }
        } else {
            current = nil
            finishWaiters(nil)
        }
    }
}

extension LocationAccess: CLLocationManagerDelegate {
    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorizationChanged(status) }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.receive(last) }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient; requestLocation reports it once.
        Task { @MainActor in self.finishWaiters(nil) }
    }
}
#endif
