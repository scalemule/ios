#if canImport(UIKit) && !os(watchOS)
import AVFoundation
import SwiftUI
import UIKit

/// Shows the camera session. The view's own layer is the preview layer, so it
/// sizes with the view and shows the picture as soon as the session runs; a
/// rotation coordinator keeps it (and the photo) level when the phone turns.
/// Tap focuses there, double-tap switches cameras, pinch zooms.
@available(iOS 17.0, *)
public struct CapturePreview: UIViewRepresentable {
    @ObservedObject var cameraManager: CaptureController
    var onFocus: (CGPoint) -> Void
    var onDoubleTap: () -> Void

    public init(controller: CaptureController, onFocus: @escaping (CGPoint) -> Void = { _ in }, onDoubleTap: @escaping () -> Void = {}) {
        self.cameraManager = controller
        self.onFocus = onFocus
        self.onDoubleTap = onDoubleTap
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = cameraManager.session
        view.previewLayer.videoGravity = .resizeAspectFill
        cameraManager.captureRotationAngle = { [weak view] in view?.captureRotationAngle }

        let coordinator = context.coordinator
        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.require(toFail: doubleTap)
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinched(_:)))
        [doubleTap, tap, pinch].forEach(view.addGestureRecognizer)
        return view
    }

    public func updateUIView(_ view: PreviewUIView, context: Context) {
        view.follow(cameraManager.currentDevice)
        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.cameraManager = cameraManager
        coordinator.onFocus = onFocus
        coordinator.onDoubleTap = onDoubleTap
    }

    @MainActor
    public final class Coordinator: NSObject {
        weak var view: PreviewUIView?
        var cameraManager: CaptureController?
        var onFocus: (CGPoint) -> Void = { _ in }
        var onDoubleTap: () -> Void = {}

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            cameraManager?.focus(at: view.previewLayer.captureDevicePointConverted(fromLayerPoint: point))
            onFocus(point)
        }

        @objc func doubleTapped() { onDoubleTap() }

        @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began: cameraManager?.pinch(began: true, scale: gesture.scale)
            case .changed: cameraManager?.pinch(began: false, scale: gesture.scale)
            default: break
            }
        }
    }

    public final class PreviewUIView: UIView {
        override public class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        public var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        private var coordinator: AVCaptureDevice.RotationCoordinator?
        private var observation: NSKeyValueObservation?

        override public init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        var captureRotationAngle: CGFloat? { coordinator?.videoRotationAngleForHorizonLevelCapture }

        func follow(_ device: AVCaptureDevice?) {
            guard let device else { return }
            if let coordinator, coordinator.device == device {
                // The preview connection can appear after the coordinator: re-apply.
                apply(coordinator.videoRotationAngleForHorizonLevelPreview)
                return
            }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            self.coordinator = coordinator
            apply(coordinator.videoRotationAngleForHorizonLevelPreview)
            observation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async { self?.apply(angle) }
            }
        }

        private func apply(_ angle: CGFloat) {
            guard let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }
    }
}
#endif
