import XCTest
@testable import ScaleMuleCapture

final class CaptureLifecycleTests: XCTestCase {
    func testForegroundDoesNotOpenCameraUntilRequested() {
        var lifecycle = CaptureSessionLifecycle(isBackgrounded: true)
        lifecycle.isBackgrounded = false
        XCTAssertFalse(lifecycle.shouldRun)
    }

    func testBackgroundResumePreservesCameraIntent() {
        var lifecycle = CaptureSessionLifecycle()
        lifecycle.requestStart()
        XCTAssertTrue(lifecycle.shouldRun)
        lifecycle.isBackgrounded = true
        XCTAssertFalse(lifecycle.shouldRun)
        lifecycle.isBackgrounded = false
        XCTAssertTrue(lifecycle.shouldRun)
    }

    func testLeavingCaptureDuringInterruptionPreventsLateResume() {
        var lifecycle = CaptureSessionLifecycle()
        lifecycle.requestStart()
        lifecycle.isBackgrounded = true
        lifecycle.requestStop()
        lifecycle.isBackgrounded = false
        XCTAssertFalse(lifecycle.shouldRun, "A late foreground or interruption-ended event must not restart a hidden camera")
        XCTAssertFalse(lifecycle.recoverAfterMediaServicesReset())
    }

    func testCameraOpenedInBackgroundWaitsForForeground() {
        var lifecycle = CaptureSessionLifecycle(isBackgrounded: true)
        lifecycle.requestStart()
        XCTAssertFalse(lifecycle.shouldRun)
        lifecycle.isBackgrounded = false
        XCTAssertTrue(lifecycle.shouldRun)
    }

    func testMediaServicesResetRecoveryIsBoundedAndManualRetryRenewsIt() {
        var lifecycle = CaptureSessionLifecycle()
        lifecycle.requestStart()
        XCTAssertTrue(lifecycle.recoverAfterMediaServicesReset())
        XCTAssertFalse(lifecycle.recoverAfterMediaServicesReset(), "Repeated failures must surface rather than loop")
        lifecycle.requestStart()
        XCTAssertTrue(lifecycle.recoverAfterMediaServicesReset())
    }

    func testBackgroundMediaResetDoesNotStartCameraOrConsumeForegroundRecovery() {
        var lifecycle = CaptureSessionLifecycle()
        lifecycle.requestStart()
        lifecycle.isBackgrounded = true
        XCTAssertFalse(lifecycle.recoverAfterMediaServicesReset())
        lifecycle.isBackgrounded = false
        XCTAssertTrue(lifecycle.recoverAfterMediaServicesReset())
    }

    func testUnknownInterruptionHasHonestFallback() {
        XCTAssertEqual(CaptureInterruption(reasonCode: -1), .unavailable)
        XCTAssertEqual(CaptureInterruption(reasonCode: 3), .cameraInUse)
        XCTAssertEqual(CaptureInterruption(reasonCode: 2), .microphoneInUse)
    }
}

#if canImport(UIKit) && !os(watchOS)
import UIKit

@available(iOS 17.0, *)
@MainActor
final class CaptureScreenSharingTests: XCTestCase {
    func testPreviewReportsCaptureChangesAndClearsWhenDetached() async {
        let view = CapturePreview.PreviewUIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var states: [Bool] = []
        view.onScreenCaptureChange = { states.append($0) }
        let controller = UIViewController()
        controller.view.addSubview(view)
        let window = UIWindow(frame: view.bounds)
        window.rootViewController = controller
        window.isHidden = false
        view.traitOverrides.sceneCaptureState = .active
        view.updateTraitsIfNeeded()
        await Task.yield()
        XCTAssertEqual(states.last, true)
        view.traitOverrides.sceneCaptureState = .inactive
        view.updateTraitsIfNeeded()
        await Task.yield()
        XCTAssertEqual(states.last, false)
        view.traitOverrides.sceneCaptureState = .active
        view.updateTraitsIfNeeded()
        await Task.yield()
        XCTAssertEqual(states.last, true)
        view.removeFromSuperview()
        XCTAssertEqual(states.last, false, "Leaving a mirrored preview must not leave a stale warning")
        window.isHidden = true
    }
}
#endif
