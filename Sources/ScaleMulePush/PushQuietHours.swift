import Foundation
import ScaleMuleCore

/// A recurring local-time schedule. A nil timezone follows each receiving device,
/// including travel and daylight-saving changes. A named zone is an explicit override.
public struct PushQuietHours: Equatable, Sendable {
    public var enabled: Bool
    public var startMinutes: Int
    public var endMinutes: Int
    public var timeZoneIdentifier: String?
    public init(enabled: Bool = true, startMinutes: Int = 22 * 60, endMinutes: Int = 8 * 60,
                timeZoneIdentifier: String? = nil) {
        self.enabled = enabled; self.startMinutes = startMinutes; self.endMinutes = endMinutes
        self.timeZoneIdentifier = timeZoneIdentifier
    }
    public static let overnight = PushQuietHours()
    public var followsDevice: Bool { timeZoneIdentifier == nil }
    public var isValid: Bool {
        if let zone = timeZoneIdentifier, TimeZone(identifier: zone) == nil { return false }
        return (0..<1440).contains(startMinutes) && (0..<1440).contains(endMinutes) && startMinutes != endMinutes
    }
    public var start: String { Self.time(startMinutes) }
    public var end: String { Self.time(endMinutes) }
    private static func time(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
    static func minutes(_ value: String?) -> Int? {
        guard let value else { return nil }
        let parts = value.split(separator: ":")
        guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }
    public func isQuiet(at date: Date = Date(), deviceTimeZone: TimeZone = .autoupdatingCurrent) -> Bool {
        guard enabled, isValid else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? deviceTimeZone
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return startMinutes < endMinutes ? minute >= startMinutes && minute < endMinutes : minute >= startMinutes || minute < endMinutes
    }
}

public struct PushPreferences: Decodable, Sendable {
    public let marketingEnabled: Bool
    public let transactionalEnabled: Bool
    public let alertEnabled: Bool
    public let quietHoursEnabled: Bool
    public let quietHoursStart: String?
    public let quietHoursEnd: String?
    public let quietHoursTimeZone: String?
    enum CodingKeys: String, CodingKey {
        case marketingEnabled = "marketing_enabled", transactionalEnabled = "transactional_enabled", alertEnabled = "alert_enabled"
        case quietHoursEnabled = "quiet_hours_enabled", quietHoursStart = "quiet_hours_start", quietHoursEnd = "quiet_hours_end", quietHoursTimeZone = "quiet_hours_tz"
    }
    public var quietHours: PushQuietHours {
        PushQuietHours(enabled: quietHoursEnabled, startMinutes: PushQuietHours.minutes(quietHoursStart) ?? 22 * 60,
            endMinutes: PushQuietHours.minutes(quietHoursEnd) ?? 8 * 60, timeZoneIdentifier: quietHoursTimeZone)
    }
}

extension PushService {
    public func preferences() async -> ApiResponse<PushPreferences> {
        await client.request(RequestOptions(method: .get, path: "/v1/communication/push/preferences", credential: .sessionToken))
    }
    /// Updates only quiet hours; preserves category choices and other devices.
    public func setQuietHours(_ schedule: PushQuietHours) async -> ApiResponse<PushPreferences> {
        guard let session = await client.sessionManager.sessionToken else {
            return .failure(ApiError(code: .unauthorized, message: "Sign in to change notifications.", statusCode: 401))
        }
        return await setQuietHours(schedule, session: session)
    }
    func preferences(session: String) async -> ApiResponse<PushPreferences> {
        await client.request(RequestOptions(method: .get, path: "/v1/communication/push/preferences", credential: .none,
            headers: ["Authorization": "Bearer \(session)"]))
    }
    func setQuietHours(_ schedule: PushQuietHours, session: String) async -> ApiResponse<PushPreferences> {
        guard schedule.isValid else { return .failure(ApiError(code: .unknown, message: "Choose different start and end times.")) }
        var body: [String: Any] = ["quiet_hours_enabled": schedule.enabled, "quiet_hours_start": schedule.start,
            "quiet_hours_end": schedule.end, "quiet_hours_follow_device": schedule.followsDevice]
        if let zone = schedule.timeZoneIdentifier { body["quiet_hours_tz"] = zone }
        return await client.request(RequestOptions(method: .put, path: "/v1/communication/push/preferences",
            body: body, credential: .none, headers: ["Authorization": "Bearer \(session)"]))
    }
}
