#if canImport(UIKit) && !os(watchOS)
// Which way the phone is physically held. Capture screens usually stay
// upright (like Instagram and Snapchat): turn icons by `angle` to face the
// person, and turn a full-screen picture, instead of the whole layout jumping.

import SwiftUI
import Combine
import UIKit

@MainActor
public final class DeviceTilt: ObservableObject {
    public static let shared = DeviceTilt()

    /// Rotation that makes content upright for the person: 0 when the phone
    /// is upright, ±90° when it is on its side. Lying flat keeps the last value.
    @Published public private(set) var angle: Angle = .zero

    public var isSideways: Bool { angle != .zero }

    private var observer: NSObjectProtocol?

    private init() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        update(UIDevice.current.orientation)
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(UIDevice.current.orientation) }
        }
    }

    private func update(_ orientation: UIDeviceOrientation) {
        switch orientation {
        case .portrait: angle = .zero
        // Home side on the right: the top of the phone points left.
        case .landscapeLeft: angle = .degrees(90)
        case .landscapeRight: angle = .degrees(-90)
        default: break // face up/down, upside down, unknown
        }
    }
}
#endif
