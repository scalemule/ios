import Foundation
import Network

// Port of the web SDK's upload-strategy.ts / upload-compression.ts profiles.
// Browsers report `navigator.connection.effectiveType`; iOS does not, so the
// class comes from the interface (Wi-Fi, cellular), Low Data Mode, and the
// upload speed this device actually achieved on recent uploads.

/// Connection quality, named like the browser's `effectiveType`.
public enum NetworkClass: String, Sendable, CaseIterable {
    case slow2g = "slow-2g"
    case twoG = "2g"
    case threeG = "3g"
    case fourG = "4g"
    case unknown

    var isSlow: Bool { self == .slow2g || self == .twoG || self == .threeG }
}

/// What the device knows about its connection right now.
public struct NetworkSnapshot: Sendable, Equatable {
    public enum Interface: String, Sendable {
        case wifi, cellular, wired, other, none
    }

    public let interface: Interface
    /// Cellular or a personal hotspot.
    public let isExpensive: Bool
    /// Low Data Mode is on.
    public let isConstrained: Bool
    /// Upload speed measured on this interface in the last 15 minutes.
    public let measuredUplinkMbps: Double?

    public init(interface: Interface, isExpensive: Bool, isConstrained: Bool, measuredUplinkMbps: Double?) {
        self.interface = interface
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.measuredUplinkMbps = measuredUplinkMbps
    }

    public var networkClass: NetworkClass {
        if interface == .none { return .unknown }
        // Low Data Mode is the person asking to send less (the browser's saveData).
        if isConstrained { return .twoG }
        if let mbps = measuredUplinkMbps {
            if mbps < 0.15 { return .slow2g }
            if mbps < 0.6 { return .twoG }
            if mbps < 2.5 { return .threeG }
            return .fourG
        }
        switch interface {
        case .wifi, .wired: return .fourG
        case .cellular: return .threeG
        case .other, .none: return .unknown
        }
    }
}

/// Watches the connection and remembers measured upload speed per interface.
public final class NetworkConditions: @unchecked Sendable {
    public static let shared = NetworkConditions()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var path: NWPath?
    private var measurement: Measurement?
    private let defaults: UserDefaults
    /// Tests: a fixed answer instead of the live path.
    private let fixed: NetworkSnapshot?
    private static let storageKey = "com.scalemule.sdk.uplinkMeasurement"
    /// Older measurements say little about the network the person is on now.
    private static let measurementLifetime: TimeInterval = 15 * 60

    private struct Measurement: Codable {
        var interface: String
        var bitsPerSecond: Double
        var measuredAt: Date
    }

    /// A fixed connection, for tests and previews.
    public init(fixed: NetworkSnapshot) {
        self.defaults = UserDefaults(suiteName: "com.scalemule.sdk.fixed-network") ?? .standard
        self.fixed = fixed
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.fixed = nil
        if let data = defaults.data(forKey: Self.storageKey) {
            measurement = try? JSONDecoder().decode(Measurement.self, from: data)
        }
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.path = path
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "com.scalemule.sdk.network-conditions"))
    }

    public func snapshot() -> NetworkSnapshot {
        if let fixed { return fixed }
        lock.lock()
        defer { lock.unlock() }
        let interface = Self.interface(of: path)
        var mbps: Double?
        if let measurement, measurement.interface == interface.rawValue,
           Date().timeIntervalSince(measurement.measuredAt) < Self.measurementLifetime {
            mbps = measurement.bitsPerSecond / 1_000_000
        }
        return NetworkSnapshot(
            interface: interface,
            isExpensive: path?.isExpensive ?? false,
            isConstrained: path?.isConstrained ?? false,
            measuredUplinkMbps: mbps
        )
    }

    /// Record a finished transfer. Small or instant ones say nothing about speed.
    public func recordUpload(bytes: Int, seconds: TimeInterval) {
        guard fixed == nil, bytes >= 64 * 1024, seconds > 0.05 else { return }
        let sample = Double(bytes) * 8 / seconds
        lock.lock()
        let interface = Self.interface(of: path).rawValue
        let now = Date()
        if var current = measurement, current.interface == interface,
           now.timeIntervalSince(current.measuredAt) < Self.measurementLifetime {
            // Smooth so one lucky or unlucky part does not swing the class.
            current.bitsPerSecond = current.bitsPerSecond * 0.6 + sample * 0.4
            current.measuredAt = now
            measurement = current
        } else {
            measurement = Measurement(interface: interface, bitsPerSecond: sample, measuredAt: now)
        }
        let saved = measurement
        lock.unlock()
        if let saved, let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private static func interface(of path: NWPath?) -> NetworkSnapshot.Interface {
        guard let path, path.status == .satisfied else { return path == nil ? .other : .none }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return .other
    }
}

/// Direct single PUT, or S3 multipart with per-part retry and resume.
public enum UploadStrategyKind: String, Sendable {
    case direct
    case multipart
}

public struct UploadPlan: Sendable, Equatable {
    public let strategy: UploadStrategyKind
    public let chunkSize: Int
    public let concurrency: Int
    /// No bytes moving for this long counts as a stall (the request is retried).
    public let stallTimeout: TimeInterval
    public let networkClass: NetworkClass
}

public enum UploadStrategy {
    static let multipartThreshold = 8 * 1024 * 1024
    /// Lower on slow networks so even a photo gets per-part retry and resume.
    static let multipartThresholdSlow = 1 * 1024 * 1024
    static let stallTimeout: TimeInterval = 45
    static let stallTimeoutSlow: TimeInterval = 90
    static let largeFileChunk = 16 * 1024 * 1024

    public static func plan(
        size: Int,
        network: NetworkSnapshot,
        forceMultipart: Bool = false,
        chunkSize: Int? = nil,
        concurrency: Int? = nil
    ) -> UploadPlan {
        let networkClass = network.networkClass
        let threshold = networkClass.isSlow ? multipartThresholdSlow : multipartThreshold
        let strategy: UploadStrategyKind = forceMultipart || size >= threshold ? .multipart : .direct
        let chunk = chunkSize ?? (size > 512 * 1024 * 1024 ? largeFileChunk : defaultChunk(networkClass))
        return UploadPlan(
            strategy: strategy,
            chunkSize: chunk,
            concurrency: max(1, concurrency ?? adaptConcurrency(networkClass, measuredMbps: network.measuredUplinkMbps)),
            stallTimeout: networkClass.isSlow ? stallTimeoutSlow : stallTimeout,
            networkClass: networkClass
        )
    }

    static func defaultChunk(_ networkClass: NetworkClass) -> Int {
        switch networkClass {
        case .slow2g, .twoG, .threeG: return 5 * 1024 * 1024
        case .fourG, .unknown: return 8 * 1024 * 1024
        }
    }

    /// Measured bandwidth wins: <0.5 Mbps 1, <2 2, <10 3, else 5 parts at once.
    static func adaptConcurrency(_ networkClass: NetworkClass, measuredMbps: Double?) -> Int {
        if let mbps = measuredMbps {
            if mbps < 0.5 { return 1 }
            if mbps < 2 { return 2 }
            if mbps < 10 { return 3 }
            return 5
        }
        switch networkClass {
        case .slow2g, .twoG: return 1
        case .threeG: return 2
        case .fourG, .unknown: return 4
        }
    }
}

/// Largest side, JPEG quality and a size target for a compressed image.
public struct ImageCompressionProfile: Sendable, Equatable {
    public var maxPixelSize: Int
    public var quality: Double
    public var maxBytes: Int

    public init(maxPixelSize: Int, quality: Double, maxBytes: Int) {
        self.maxPixelSize = maxPixelSize
        self.quality = quality
        self.maxBytes = maxBytes
    }

    /// The web SDK's network profiles.
    public static func forNetwork(_ networkClass: NetworkClass) -> ImageCompressionProfile {
        switch networkClass {
        case .slow2g: return ImageCompressionProfile(maxPixelSize: 1280, quality: 0.6, maxBytes: 512 * 1024)
        case .twoG: return ImageCompressionProfile(maxPixelSize: 1600, quality: 0.65, maxBytes: 1024 * 1024)
        case .threeG: return ImageCompressionProfile(maxPixelSize: 2048, quality: 0.75, maxBytes: 2 * 1024 * 1024)
        case .fourG, .unknown: return ImageCompressionProfile(maxPixelSize: 3840, quality: 0.85, maxBytes: 5 * 1024 * 1024)
        }
    }
}
