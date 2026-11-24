#if canImport(UIKit) && !os(watchOS)
import AVFoundation
import Combine
import UIKit
import os.log

/// One recorded clip of a take.
public struct CaptureClip: Sendable, Equatable, Identifiable {
    public let url: URL
    public let duration: Double
    public var id: URL { url }
}

/// A lens button: the device zoom factor and the number people see (0.5, 1, 2, 4).
public struct ZoomPreset: Identifiable, Equatable, Sendable {
    public let factor: CGFloat
    public let display: CGFloat

    public var id: CGFloat { factor }

    public init(factor: CGFloat, display: CGFloat) {
        self.factor = factor
        self.display = display
    }

    /// "0.5", "1", "2", "4" (the Camera app's style).
    public var label: String {
        let rounded = (display * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded).replacingOccurrences(of: "0.", with: ".")
    }
}

public enum CaptureError: Error, LocalizedError, Sendable {
    case permissionDenied
    case cameraUnavailable
    case cannotAddInput
    case cannotAddOutput
    case setupFailed(String)
    case sessionNotRunning
    case alreadyCapturing
    case captureFailed(String)
    case imageConversionFailed

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Camera access is off. Turn it on in Settings."
        case .cameraUnavailable: return "This device has no camera the app can use."
        case .cannotAddInput, .cannotAddOutput, .setupFailed: return "The camera couldn't start. Try again."
        case .sessionNotRunning: return "The camera is still starting. Try again in a moment."
        case .alreadyCapturing: return "A photo is already being taken."
        case .captureFailed, .imageConversionFailed: return "That didn't come through. Try again."
        }
    }
}

/// The camera, for apps with a capture screen like Instagram's or TikTok's.
///
/// Photos: `capturePhoto()` (up to 12 MP, flash, mirrored front camera,
/// saved upright for how the phone is held).
///
/// Videos are takes of one or more clips: `startClip()` on press,
/// `stopClip()` on release, again to add clips, `deleteLastClip()`, then
/// `finishTake()` hands over the files (join and edit them with
/// `VideoComposer`). A take keeps the orientation of its first clip and
/// stops at `maxVideoSeconds` in total. The session switches to a video
/// preset with a movie output and the microphone only for a take (as Apple's
/// AVCam does), so the orange microphone dot is never on for photos.
///
/// Show `session` with `CapturePreview`; zoom with `zoom(to:)` / `pinch`,
/// focus with `focus(at:)`, flip with `switchCamera()`.
@available(iOS 17.0, *)
@MainActor
public final class CaptureController: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "com.scalemule.sdk", category: "Capture")

    @Published public private(set) var isSessionRunning = false
    @Published public private(set) var interruption: CaptureInterruption?
    /// A hint for the UI, not a capture prohibition: recording and mirroring
    /// share this public iOS signal, and not all of them suppress camera frames.
    @Published public internal(set) var isPreviewScreenCaptured = false
    /// The last photo taken.
    @Published public private(set) var capturedImage: UIImage?
    @Published public private(set) var isCapturing = false
    @Published public private(set) var currentCameraPosition: AVCaptureDevice.Position = .back
    /// The camera in use (the preview follows it to keep the picture level).
    @Published public private(set) var currentDevice: AVCaptureDevice?
    @Published public private(set) var flashMode: AVCaptureDevice.FlashMode = .auto
    @Published public private(set) var hasFlash = true
    /// Lens buttons for this camera (0.5×, 1×, 2×, telephoto).
    @Published public private(set) var zoomPresets: [ZoomPreset] = []
    /// Zoom as people read it (1 = the main camera).
    @Published public private(set) var displayZoom: CGFloat = 1
    @Published public var error: CaptureError?

    // Takes
    @Published public private(set) var isRecording = false
    /// Finished clips of the take in progress.
    @Published public private(set) var clips: [CaptureClip] = []
    /// Seconds in the take, including the clip being recorded.
    @Published public private(set) var recordedSeconds: Double = 0

    /// Longest take, all clips together.
    public let maxVideoSeconds: Double
    /// A press shorter than this records nothing.
    public let minClipSeconds: Double

    public var clipsDuration: Double { clips.reduce(0) { $0 + $1.duration } }
    public var isTakeFull: Bool { clipsDuration >= maxVideoSeconds - 0.05 }
    public var hasTake: Bool { !clips.isEmpty || isRecording }

    /// Shown by `CapturePreview`.
    nonisolated public let session = AVCaptureSession()

    // Used only on sessionQueue.
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private let movieOutput = AVCaptureMovieFileOutput()
    nonisolated(unsafe) private var currentInput: AVCaptureDeviceInput?
    nonisolated(unsafe) private var audioInput: AVCaptureDeviceInput?
    nonisolated(unsafe) private var isConfigured = false
    nonisolated(unsafe) private var inMovieMode = false
    nonisolated(unsafe) private var stopRequested = false
    nonisolated(unsafe) private var pinchStartFactor: CGFloat = 1
    nonisolated(unsafe) private var lifecycle: CaptureSessionLifecycle
    nonisolated private let sessionQueue = DispatchQueue(label: "com.scalemule.capture.session", qos: .userInitiated)

    /// Rotation for the next capture, from the preview's rotation coordinator.
    public var captureRotationAngle: () -> CGFloat? = { nil }
    /// The whole take uses its first clip's rotation.
    private var takeRotation: CGFloat?
    private var recordingTimer: Task<Void, Never>?
    private var photoCaptureCompletion: ((Result<UIImage, CaptureError>) -> Void)?

    public init(maxVideoSeconds: Double = 60, minClipSeconds: Double = 0.3) {
        self.maxVideoSeconds = maxVideoSeconds
        self.minClipSeconds = minClipSeconds
        self.lifecycle = CaptureSessionLifecycle(isBackgrounded: UIApplication.shared.applicationState == .background)
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError(_:)), name: AVCaptureSession.runtimeErrorNotification, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionStateChanged(_:)), name: AVCaptureSession.didStartRunningNotification, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionStateChanged(_:)), name: AVCaptureSession.didStopRunningNotification, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterrupted(_:)), name: AVCaptureSession.wasInterruptedNotification, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)), name: AVCaptureSession.interruptionEndedNotification, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationBackgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationForegrounded), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Permission

    public static func cameraPermission() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    public static func requestCameraPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    public static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: - Session

    /// Sets the session up the first time, then starts it.
    public func startSession() {
        let position = currentCameraPosition
        error = nil
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.lifecycle.requestStart()
            self.resumeSession(position: position)
        }
    }

    public func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.lifecycle.requestStop()
            self.pauseSession()
            Task { @MainActor in self.interruption = nil }
        }
    }

    nonisolated private func resumeSession(position: AVCaptureDevice.Position = .back) {
        guard lifecycle.shouldRun else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            Task { @MainActor in self.error = .permissionDenied; self.isSessionRunning = false }
            return
        }
        if !isConfigured {
            if let failure = configureSession(position: position) {
                logger.error("Camera setup failed: \(failure.localizedDescription)")
                Task { @MainActor in self.error = failure; self.isSessionRunning = false }
                return
            }
            isConfigured = true
            publishDevice()
        }
        if !session.isRunning && !session.isInterrupted { session.startRunning() }
        if !session.isRunning && !session.isInterrupted {
            logger.error("Capture session did not start")
            Task { @MainActor in
                self.error = .setupFailed("Capture session did not start")
                self.isSessionRunning = false
            }
            return
        }
        publishSessionState()
    }

    nonisolated private func pauseSession() {
        // A microphone permission result may arrive after the camera was left.
        stopRequested = true
        if movieOutput.isRecording { movieOutput.stopRecording() }
        if session.isRunning { session.stopRunning() }
        publishSessionState()
    }

    nonisolated private func publishSessionState() {
        let running = lifecycle.shouldRun && session.isRunning && !session.isInterrupted
        Task { @MainActor in
            self.isSessionRunning = running
            if running { self.error = nil; self.interruption = nil }
        }
    }

    @objc nonisolated private func sessionStateChanged(_ note: Notification) {
        sessionQueue.async { [weak self] in self?.publishSessionState() }
    }

    @objc nonisolated private func sessionInterrupted(_ note: Notification) {
        let reasonCode = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? 0
        logger.info("Capture session interrupted, reason: \(reasonCode)")
        sessionQueue.async { [weak self] in
            guard let self, self.lifecycle.isRequested else { return }
            Task { @MainActor in
                self.interruption = CaptureInterruption(reasonCode: reasonCode)
                self.isSessionRunning = false
            }
        }
    }

    @objc nonisolated private func sessionInterruptionEnded(_ note: Notification) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.interruption = nil }
            // In particular, a late notification must not restart a hidden camera.
            self.resumeSession()
        }
    }

    @objc nonisolated private func applicationBackgrounded() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.lifecycle.isBackgrounded = true
            self.pauseSession()
        }
    }

    @objc nonisolated private func applicationForegrounded() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.lifecycle.isBackgrounded = false
            self.resumeSession()
        }
    }

    nonisolated private func configureSession(position: AVCaptureDevice.Position) -> CaptureError? {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        guard let camera = Self.camera(for: position) else { return .cameraUnavailable }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: camera)
        } catch {
            return .setupFailed(error.localizedDescription)
        }
        guard session.canAddInput(input) else { return .cannotAddInput }
        session.addInput(input)
        currentInput = input
        guard session.canAddOutput(photoOutput) else {
            session.removeInput(input)
            currentInput = nil
            return .cannotAddOutput
        }
        session.addOutput(photoOutput)
        // Up to 12 MP: 48 MP shots are slow to take and larger than posts need.
        let sizes = camera.activeFormat.supportedMaxPhotoDimensions.sorted { $0.width * $0.height < $1.width * $1.height }
        if let size = sizes.last(where: { Int($0.width) * Int($0.height) <= 12_600_000 }) ?? sizes.first {
            photoOutput.maxPhotoDimensions = size
        }
        Self.startAtMainCamera(camera)
        photoOutput.maxPhotoQualityPrioritization = .balanced
        updateMirroring(for: position)
        return nil
    }

    /// Front-camera photos match the mirrored preview people framed them in.
    nonisolated private func updateMirroring(for position: AVCaptureDevice.Position) {
        guard let connection = photoOutput.connection(with: .video), connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = position == .front
    }

    @objc nonisolated private func sessionRuntimeError(_ note: Notification) {
        let failure = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
        let message = failure?.localizedDescription ?? "unknown"
        let mediaServicesReset = failure?.domain == AVFoundationErrorDomain && failure?.code == AVError.mediaServicesWereReset.rawValue
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.logger.error("Capture session error: \(message)")
            if mediaServicesReset, self.lifecycle.recoverAfterMediaServicesReset() {
                self.resumeSession()
            } else {
                Task { @MainActor in
                    self.error = .setupFailed(message)
                    self.isSessionRunning = false
                }
            }
        }
    }

    // MARK: - Photos

    @discardableResult
    public func capturePhoto() async throws -> UIImage {
        guard !isCapturing else { throw CaptureError.alreadyCapturing }
        guard isSessionRunning else { throw CaptureError.sessionNotRunning }
        isCapturing = true
        let flash = flashMode
        let angle = captureRotationAngle()
        return try await withCheckedThrowingContinuation { continuation in
            photoCaptureCompletion = { result in continuation.resume(with: result.mapError { $0 as Error }) }
            sessionQueue.async { [weak self] in
                guard let self else { return }
                let settings = AVCapturePhotoSettings()
                if let device = self.currentInput?.device, device.hasFlash, self.photoOutput.supportedFlashModes.contains(flash) {
                    settings.flashMode = flash
                }
                settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                if let angle, let connection = self.photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    public func clearCapturedImage() {
        capturedImage = nil
    }

    public func toggleFlash() {
        switch flashMode {
        case .auto: flashMode = .on
        case .on: flashMode = .off
        default: flashMode = .auto
        }
    }

    // MARK: - Takes (multi-clip video)

    /// Press: record a clip (the first one starts the take).
    public func startClip() {
        guard !isRecording, !isCapturing, isSessionRunning, !isTakeFull else { return }
        isRecording = true
        if takeRotation == nil { takeRotation = captureRotationAngle() }
        let angle = takeRotation
        let mirrored = currentCameraPosition == .front
        let remaining = maxVideoSeconds - clipsDuration
        let base = clipsDuration
        // A release from now on, even before the camera starts, ends this clip.
        sessionQueue.async { [weak self] in self?.stopRequested = false }
        Task {
            let withAudio = await Self.microphoneAllowed()
            sessionQueue.async { [weak self] in
                self?.beginClip(audio: withAudio, angle: angle, mirrored: mirrored, maxSeconds: remaining)
            }
        }
        recordingTimer?.cancel()
        let started = Date()
        recordingTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, self.isRecording else { return }
                self.recordedSeconds = min(base + Date().timeIntervalSince(started), self.maxVideoSeconds)
            }
        }
    }

    /// Release: finish the clip (it joins `clips` when written).
    public func stopClip() {
        guard isRecording else { return }
        recordingTimer?.cancel()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            } else {
                // Released before the camera had started: stop as soon as it does.
                self.stopRequested = true
            }
        }
    }

    public func deleteLastClip() {
        guard !isRecording, let last = clips.popLast() else { return }
        try? FileManager.default.removeItem(at: last.url)
        recordedSeconds = clipsDuration
        if clips.isEmpty { takeRotation = nil }
    }

    /// Hands the clips over (the caller owns the files) and leaves video
    /// mode. Empty while a clip is still being recorded or written: call it
    /// when `isRecording` is false.
    public func finishTake() -> [URL] {
        guard !isRecording else { return [] }
        let urls = clips.map(\.url)
        resetTake()
        return urls
    }

    /// Throws the take away.
    public func discardTake() {
        guard !isRecording else { return }
        for clip in clips { try? FileManager.default.removeItem(at: clip.url) }
        resetTake()
    }

    private func resetTake() {
        clips = []
        recordedSeconds = 0
        takeRotation = nil
        sessionQueue.async { [weak self] in self?.endMovieMode() }
    }

    nonisolated private func beginClip(audio: Bool, angle: CGFloat?, mirrored: Bool, maxSeconds: Double) {
        // Released while the microphone question was up: no clip.
        if stopRequested || !lifecycle.shouldRun || !session.isRunning || session.isInterrupted {
            stopRequested = false
            Task { @MainActor in
                self.recordingTimer?.cancel()
                self.isRecording = false
                self.recordedSeconds = self.clipsDuration
                if self.clips.isEmpty { self.takeRotation = nil }
            }
            return
        }
        if !inMovieMode {
            session.beginConfiguration()
            if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
            if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
            if audio, audioInput == nil, let mic = AVCaptureDevice.default(for: .audio),
               let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
                session.addInput(input)
                audioInput = input
            }
            session.commitConfiguration()
            inMovieMode = true
        }
        movieOutput.maxRecordedDuration = CMTime(seconds: max(0.5, maxSeconds), preferredTimescale: 600)
        if let connection = movieOutput.connection(with: .video) {
            if let angle, connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
            }
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .auto }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    /// Back to photo mode, microphone off.
    nonisolated private func endMovieMode() {
        guard inMovieMode else { return }
        session.beginConfiguration()
        if session.outputs.contains(movieOutput) { session.removeOutput(movieOutput) }
        if let audioInput {
            session.removeInput(audioInput)
            self.audioInput = nil
        }
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        session.commitConfiguration()
        inMovieMode = false
    }

    // MARK: - Camera switching

    /// Flipping between clips keeps the take upright only when the phone is
    /// held upright (sideways, the two cameras need different angles).
    public var canSwitchCamera: Bool {
        !isRecording && (clips.isEmpty || takeRotation == nil || takeRotation == 90)
    }

    public func switchCamera() {
        guard canSwitchCamera else { return }
        let newPosition: AVCaptureDevice.Position = currentCameraPosition == .back ? .front : .back
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, let newCamera = Self.camera(for: newPosition),
                  let newInput = try? AVCaptureDeviceInput(device: newCamera) else { return }
            self.session.beginConfiguration()
            if let currentInput = self.currentInput { self.session.removeInput(currentInput) }
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.currentInput = newInput
            } else if let currentInput = self.currentInput {
                self.session.addInput(currentInput)
            }
            if let device = self.currentInput?.device { Self.startAtMainCamera(device) }
            self.updateMirroring(for: self.currentInput?.device.position ?? newPosition)
            self.session.commitConfiguration()
            self.publishDevice()
        }
    }

    // MARK: - Zoom and focus

    public func zoom(to preset: ZoomPreset) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }
            self.setZoomFactor(preset.factor, on: device, ramp: true)
        }
    }

    /// Pinch: `scale` is the gesture's scale since it began.
    public func pinch(began: Bool, scale: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }
            if began { self.pinchStartFactor = device.videoZoomFactor }
            self.setZoomFactor(self.pinchStartFactor * scale, on: device, ramp: false)
        }
    }

    /// Focus and expose at a point in device coordinates (0...1, from the preview layer).
    public func focus(at point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let device = self?.currentInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .autoExpose
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
            } catch {}
        }
    }

    @objc nonisolated private func subjectAreaChanged(_ note: Notification) {
        sessionQueue.async { [weak self] in
            guard let device = self?.currentInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
                    device.exposureMode = .continuousAutoExposure
                }
                device.isSubjectAreaChangeMonitoringEnabled = false
                device.unlockForConfiguration()
            } catch {}
        }
    }

    /// Lenses beyond 10× the main camera are digital mush.
    nonisolated private func zoomLimits(for device: AVCaptureDevice) -> ClosedRange<CGFloat> {
        let main = Self.mainCameraFactor(device)
        let upper = min(device.maxAvailableVideoZoomFactor, main * 10)
        return device.minAvailableVideoZoomFactor...max(device.minAvailableVideoZoomFactor, upper)
    }

    nonisolated private func setZoomFactor(_ factor: CGFloat, on device: AVCaptureDevice, ramp: Bool) {
        let limits = zoomLimits(for: device)
        let target = min(max(factor, limits.lowerBound), limits.upperBound)
        do {
            try device.lockForConfiguration()
            if ramp {
                device.ramp(toVideoZoomFactor: target, withRate: 12)
            } else {
                device.cancelVideoZoomRamp()
                device.videoZoomFactor = target
            }
            device.unlockForConfiguration()
        } catch { return }
        let display = target * Self.zoomMultiplier(device)
        Task { @MainActor in self.displayZoom = display }
    }

    /// Phones with an ultra-wide camera report zoom 1 as the ultra-wide; open at the main camera.
    nonisolated private static func startAtMainCamera(_ device: AVCaptureDevice) {
        let main = mainCameraFactor(device)
        guard main != device.videoZoomFactor else { return }
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = main
            device.unlockForConfiguration()
        } catch {}
    }

    /// Device zoom factor to the number people see (iOS 18 reports it; before
    /// that, a camera with an ultra-wide lens shows 1× at its first switch-over).
    nonisolated private static func zoomMultiplier(_ device: AVCaptureDevice) -> CGFloat {
        if #available(iOS 18.0, *) { return device.displayVideoZoomFactorMultiplier }
        let ultraWide = [.builtInTripleCamera, .builtInDualWideCamera].contains(device.deviceType)
        guard ultraWide, let first = device.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue, first > 0 else { return 1 }
        return 1 / CGFloat(first)
    }

    nonisolated private static func mainCameraFactor(_ device: AVCaptureDevice) -> CGFloat {
        let multiplier = Self.zoomMultiplier(device)
        return multiplier > 0 ? 1 / multiplier : 1
    }

    nonisolated private func publishDevice() {
        guard let device = currentInput?.device else { return }
        let multiplier = Self.zoomMultiplier(device)
        let main = Self.mainCameraFactor(device)
        let limits = zoomLimits(for: device)
        var factors: [CGFloat] = [device.minAvailableVideoZoomFactor, main, main * 2]
        factors += device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        var seen = Set<Int>()
        let presets = factors
            .filter { limits.contains($0) }
            .sorted()
            .compactMap { factor -> ZoomPreset? in
                let preset = ZoomPreset(factor: factor, display: factor * multiplier)
                return seen.insert(Int((preset.display * 10).rounded())).inserted ? preset : nil
            }
        let display = device.videoZoomFactor * multiplier
        let hasFlash = device.hasFlash
        let position = device.position
        NotificationCenter.default.removeObserver(self, name: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(subjectAreaChanged(_:)), name: AVCaptureDevice.subjectAreaDidChangeNotification, object: device)
        Task { @MainActor in
            self.currentDevice = device
            self.currentCameraPosition = position
            self.hasFlash = hasFlash
            self.zoomPresets = presets.count > 1 ? presets : []
            self.displayZoom = display
        }
    }

    nonisolated private static func camera(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        return discovery.devices.first ?? AVCaptureDevice.default(for: .video)
    }
}

// MARK: - Delegates

@available(iOS 17.0, *)
extension CaptureController: AVCapturePhotoCaptureDelegate {
    nonisolated public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let result: Result<UIImage, CaptureError>
        if let error {
            result = .failure(.captureFailed(error.localizedDescription))
        } else if let data = photo.fileDataRepresentation(), let image = UIImage(data: data) {
            result = .success(image)
        } else {
            result = .failure(.imageConversionFailed)
        }
        Task { @MainActor in
            self.isCapturing = false
            if case .success(let image) = result { self.capturedImage = image }
            self.photoCaptureCompletion?(result)
            self.photoCaptureCompletion = nil
        }
    }
}

@available(iOS 17.0, *)
extension CaptureController: AVCaptureFileOutputRecordingDelegate {
    nonisolated public func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        sessionQueue.async { [weak self] in
            guard let self, self.stopRequested else { return }
            self.stopRequested = false
            output.stopRecording()
        }
    }

    nonisolated public func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        // Reaching the time limit also reports an error, with the file complete.
        let finished = error == nil
            || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        let seconds = output.recordedDuration.seconds
        Task { @MainActor in
            self.recordingTimer?.cancel()
            self.isRecording = false
            if finished, seconds.isFinite, seconds >= self.minClipSeconds {
                self.clips.append(CaptureClip(url: outputFileURL, duration: seconds))
            } else {
                try? FileManager.default.removeItem(at: outputFileURL)
                if !finished { self.logger.error("Clip failed: \(error?.localizedDescription ?? "unknown")") }
            }
            self.recordedSeconds = self.clipsDuration
            if self.clips.isEmpty { self.takeRotation = nil; self.sessionQueue.async { [weak self] in self?.endMovieMode() } }
        }
    }
}
#endif
