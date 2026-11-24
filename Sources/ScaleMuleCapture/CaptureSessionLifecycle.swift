/// Session intent survives backgrounding, but never an explicit stop. Used only
/// on the camera's serial session queue, including when notifications arrive late.
struct CaptureSessionLifecycle {
    private(set) var isRequested = false
    var isBackgrounded: Bool
    private var hasRetriedMediaServicesReset = false

    init(isBackgrounded: Bool = false) { self.isBackgrounded = isBackgrounded }

    var shouldRun: Bool { isRequested && !isBackgrounded }

    mutating func requestStart() {
        isRequested = true
        hasRetriedMediaServicesReset = false
    }

    mutating func requestStop() { isRequested = false }

    mutating func recoverAfterMediaServicesReset() -> Bool {
        guard shouldRun, !hasRetriedMediaServicesReset else { return false }
        hasRetriedMediaServicesReset = true
        return true
    }
}

/// Why iOS temporarily paused camera access. These messages do not suggest that
/// restarting the app can override another app's camera access or an OS restriction.
public enum CaptureInterruption: Sendable, Equatable {
    case background
    case microphoneInUse
    case cameraInUse
    case multipleApps
    case systemPressure
    case unavailable

    init(reasonCode: Int) {
        switch reasonCode {
        case 1: self = .background
        case 2: self = .microphoneInUse
        case 3: self = .cameraInUse
        case 4: self = .multipleApps
        case 5: self = .systemPressure
        default: self = .unavailable
        }
    }

    public var message: String {
        switch self {
        case .background: return "Return to the app to use the camera."
        case .microphoneInUse: return "Another app or a call is using the microphone. The camera will resume when it is available."
        case .cameraInUse: return "Another app is using the camera. Close it to continue here."
        case .multipleApps: return "Open this app in full screen to use the camera."
        case .systemPressure: return "Your device needs a moment. The camera will resume when it is available."
        case .unavailable: return "Camera access is temporarily unavailable. It will resume when iOS allows it."
        }
    }
}
