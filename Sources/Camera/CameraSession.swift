import AVFoundation
import CoreImage
import UIKit

enum CaptureError: LocalizedError {
    case noData
    case noDevice
    case movieFailed

    var errorDescription: String? {
        switch self {
        case .noData: return "没有拿到照片数据"
        case .noDevice: return "找不到摄像头"
        case .movieFailed: return "实况照片视频处理失败"
        }
    }
}

struct LensOption: Identifiable, Hashable {
    let base: CGFloat
    let label: String

    var id: String { label }
}

/// 采集层。
///
/// 变焦走虚拟多摄设备（TripleCamera / DualWideCamera），系统内部完成镜头切换与交叉淡化。
/// 手动控制走 AVCaptureDevice 的官方 locked 模式（custom exposure / locked WB / locked focus）。
final class CameraSession: NSObject, ObservableObject {
    let session = AVCaptureSession()
    let photoOutput = AVCapturePhotoOutput()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "cam.session")
    private let videoQueue = DispatchQueue(label: "cam.video")

    private var device: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var activeDelegate: PhotoCaptureDelegate?
    private var startObserver: NSObjectProtocol?

    private var currentPosition: AVCaptureDevice.Position = .back
    private var zoomBase: CGFloat = 1
    private var didReportFrameSize = false

    private let filterLock = NSLock()
    private var activeFilter: CIFilter?

    // 供缩略图使用的取景快照（限频更新，避免每帧都存）
    private let snapshotLock = NSLock()
    private var snapshot: CIImage?
    private var lastSnapshotAt: TimeInterval = 0

    func currentSnapshot() -> CIImage? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshot
    }

    weak var renderer: PreviewRenderer?

    // MARK: - 状态

    @Published var isConfigured = false
    @Published var livePhotoSupported = false
    @Published var livePhotoEnabled = false
    @Published var errorMessage: String?

    @Published var position: AVCaptureDevice.Position = .back
    @Published var lenses: [LensOption] = []
    @Published var virtualZoom: CGFloat = 1

    @Published var exposureBias: Float = 0
    @Published var exposureRange: ClosedRange<Float> = -8...8
    @Published var focusPoint: CGPoint?
    @Published var frameAspect: CGFloat = 9.0 / 16.0

    // MARK: - 手动控制状态

    @Published var manualExposure = false
    @Published var manualWhiteBalance = false
    @Published var manualFocus = false

    @Published var iso: Float = 100
    @Published var isoRange: ClosedRange<Float> = 34...3200

    @Published var shutterSeconds: Double = 1.0 / 60.0
    @Published var shutterRange: ClosedRange<Double> = 1.0 / 8000.0 ... 1.0

    @Published var whiteBalanceTemperature: Float = 5000
    let whiteBalanceRange: ClosedRange<Float> = 2500...9000

    @Published var lensPosition: Float = 0.5

    /// 诊断信息，方便定位机型差异
    @Published var lensDebug: String = ""

    private let maxVirtualZoom: CGFloat = 15

    // MARK: - 生命周期

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured { self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
            self.refreshLivePhotoSupport()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let dev = pickDevice(for: .back) else {
            DispatchQueue.main.async { self.errorMessage = CaptureError.noDevice.localizedDescription }
            session.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: dev)
            if session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
                device = dev
            }
        } catch {
            DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
            session.commitConfiguration()
            return
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        applyConnections()
        session.commitConfiguration()

        if startObserver == nil {
            startObserver = NotificationCenter.default.addObserver(
                forName: .AVCaptureSessionDidStartRunning,
                object: session,
                queue: nil
            ) { [weak self] _ in
                self?.refreshLivePhotoSupport()
            }
        }

        applyDeviceState(dev)
    }

    /// 后摄优先虚拟多摄设备（一颗设备覆盖全部焦段）
    private func pickDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let candidates: [AVCaptureDevice.DeviceType]

        if position == .front {
            candidates = [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        } else {
            candidates = [
                .builtInTripleCamera,
                .builtInDualWideCamera,
                .builtInDualCamera,
                .builtInWideAngleCamera
            ]
        }

        for type in candidates {
            if let dev = AVCaptureDevice.default(type, for: .video, position: position) {
                return dev
            }
        }
        return nil
    }

    /// 切换设备后同步所有能力范围到界面
    private func applyDeviceState(_ dev: AVCaptureDevice) {
        let base = constituentBase(for: dev)
        let options = buildLenses(for: dev, base: base)

        if (try? dev.lockForConfiguration()) != nil {
            dev.videoZoomFactor = max(1, 1 / base)
            dev.unlockForConfiguration()
        }

        let isoLower = dev.activeFormat.minISO
        let isoUpper = dev.activeFormat.maxISO
        let minDuration = max(dev.activeFormat.minExposureDuration.seconds, 1.0 / 8000.0)
        let maxDuration = min(dev.activeFormat.maxExposureDuration.seconds, 1.0)

        DispatchQueue.main.async {
            self.zoomBase = base
            self.lenses = options
            self.virtualZoom = 1

            self.exposureRange = dev.minExposureTargetBias...dev.maxExposureTargetBias
            self.exposureBias = dev.exposureTargetBias

            self.isoRange = isoLower...isoUpper
            self.iso = min(max(dev.iso, isoLower), isoUpper)

            self.shutterRange = minDuration...maxDuration
            self.shutterSeconds = min(max(dev.exposureDuration.seconds, minDuration), maxDuration)

            self.manualExposure = false
            self.manualWhiteBalance = false
            self.manualFocus = false
            self.lensPosition = 0.5

            self.lensDebug = "\(dev.deviceType.rawValue) · 组成\(dev.constituentDevices.count) · 切换点\(dev.virtualDeviceSwitchOverVideoZoomFactors.count) · 档位\(options.count)"

            self.isConfigured = true
        }
    }

    private func constituentBase(for device: AVCaptureDevice) -> CGFloat {
        let hasUltraWide = device.constituentDevices.contains {
            $0.deviceType == .builtInUltraWideCamera
        }
        return hasUltraWide ? 0.5 : 1.0
    }

    private func buildLenses(for device: AVCaptureDevice, base: CGFloat) -> [LensOption] {
        var bases: [CGFloat] = []

        let factors = device.virtualDeviceSwitchOverVideoZoomFactors.map {
            CGFloat(truncating: $0)
        }

        if !factors.isEmpty {
            bases.append(base)
            for factor in factors {
                bases.append(base * factor)
            }
        } else {
            // 虚拟设备的 switchOver 有时为空，退回用物理组成镜头推导档位
            let constituents = device.constituentDevices
            if constituents.isEmpty {
                bases = [base]
            } else {
                bases = constituents.map { lensBase(for: $0.deviceType) }
            }
        }

        var unique: [CGFloat] = []
        for value in bases.sorted() where !unique.contains(where: { abs($0 - value) < 0.01 }) {
            unique.append(value)
        }

        // 兜底：后摄至少要给出 0.5/1/3 三个档位，否则镜头条会整条消失
        if currentPosition == .back, unique.count <= 1 {
            unique = [0.5, 1, 3]
        }

        return unique.map { LensOption(base: $0, label: formatZoom($0)) }
    }

    private func lensBase(for type: AVCaptureDevice.DeviceType) -> CGFloat {
        switch type {
        case .builtInUltraWideCamera: return 0.5
        case .builtInTelephotoCamera: return 3
        default: return 1
        }
    }

    private func formatZoom(_ value: CGFloat) -> String {
        if abs(value - value.rounded()) < 0.05 {
            return String(format: "%.0f×", value)
        }
        return String(format: "%.1f×", value)
    }

    private func refreshLivePhotoSupport() {
        let supported = photoOutput.isLivePhotoCaptureSupported

        if supported && !photoOutput.isLivePhotoCaptureEnabled {
            session.beginConfiguration()
            photoOutput.isLivePhotoCaptureEnabled = true
            session.commitConfiguration()
        }

        DispatchQueue.main.async {
            if self.livePhotoSupported != supported {
                self.livePhotoSupported = supported
            }
            let enabled = self.photoOutput.isLivePhotoCaptureEnabled
            if self.livePhotoEnabled != enabled {
                self.livePhotoEnabled = enabled
            }
        }
    }

    private func applyConnections() {
        if let conn = videoOutput.connection(with: .video) {
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = (currentPosition == .front)
            }
        }
        if let conn = photoOutput.connection(with: .video) {
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = false
            }
        }
    }

    deinit {
        if let startObserver {
            NotificationCenter.default.removeObserver(startObserver)
        }
    }

    // MARK: - 前后摄切换

    func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            let target: AVCaptureDevice.Position = (self.currentPosition == .back) ? .front : .back
            guard let newDevice = self.pickDevice(for: target),
                  let newInput = try? AVCaptureDeviceInput(device: newDevice) else { return }

            self.session.beginConfiguration()
            if let current = self.videoInput { self.session.removeInput(current) }

            guard self.session.canAddInput(newInput) else {
                if let current = self.videoInput { self.session.addInput(current) }
                self.session.commitConfiguration()
                return
            }

            self.session.addInput(newInput)
            self.videoInput = newInput
            self.device = newDevice
            self.currentPosition = target

            self.applyConnections()
            self.session.commitConfiguration()

            DispatchQueue.main.async { self.position = target }

            self.applyDeviceState(newDevice)
            self.refreshLivePhotoSupport()
        }
    }

    // MARK: - 变焦

    func setVirtualZoom(_ value: CGFloat, animated: Bool = false) {
        let vz = max(zoomBase, min(value, maxVirtualZoom))

        DispatchQueue.main.async {
            if abs(self.virtualZoom - vz) > 0.001 {
                self.virtualZoom = vz
            }
        }

        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            guard (try? device.lockForConfiguration()) != nil else { return }

            let rawFactor = vz / self.zoomBase
            let factor = max(1, min(rawFactor, device.maxAvailableVideoZoomFactor))

            if animated {
                device.ramp(toVideoZoomFactor: factor, withRate: 8)
            } else {
                device.videoZoomFactor = factor
            }
            device.unlockForConfiguration()
        }
    }

    // MARK: - 对焦与测光

    func focus(at point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            guard (try? device.lockForConfiguration()) != nil else { return }

            let clamped = CGPoint(
                x: min(max(point.x, 0.05), 0.95),
                y: min(max(point.y, 0.05), 0.95)
            )

            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = clamped
                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
            }

            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = clamped
                if device.isExposureModeSupported(.autoExpose) {
                    device.exposureMode = .autoExpose
                }
            }

            device.unlockForConfiguration()

            DispatchQueue.main.async {
                self.focusPoint = clamped
                self.manualFocus = false
                self.manualExposure = false
            }

            self.sessionQueue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, let device = self.device else { return }
                guard (try? device.lockForConfiguration()) != nil else { return }
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            }
        }
    }

    func setExposureBias(_ bias: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            let clamped = min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias)
            device.setExposureTargetBias(clamped, completionHandler: nil)
            DispatchQueue.main.async {
                if abs(self.exposureBias - clamped) > 0.01 {
                    self.exposureBias = clamped
                }
            }
        }
    }

    // MARK: - 手动控制

    /// 手动曝光：同时锁定快门与 ISO（官方 custom exposure 模式）
    func setManualExposure(iso newISO: Float, shutter seconds: Double) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            guard (try? device.lockForConfiguration()) != nil else { return }

            let clampedISO = min(max(newISO, device.activeFormat.minISO), device.activeFormat.maxISO)
            let minSeconds = device.activeFormat.minExposureDuration.seconds
            let maxSeconds = device.activeFormat.maxExposureDuration.seconds
            let clampedSeconds = min(max(seconds, minSeconds), maxSeconds)

            let duration = CMTimeMakeWithSeconds(clampedSeconds, preferredTimescale: 1_000_000)
            device.setExposureModeCustom(duration: duration, iso: clampedISO, completionHandler: nil)
            device.unlockForConfiguration()

            DispatchQueue.main.async {
                self.iso = clampedISO
                self.shutterSeconds = clampedSeconds
                self.manualExposure = true
            }
        }
    }

    func setExposureAuto() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.manualExposure = false }
        }
    }

    /// 手动白平衡：按色温换算增益后锁定
    func setManualWhiteBalance(temperature: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            guard (try? device.lockForConfiguration()) != nil else { return }

            let clamped = min(max(temperature, 2500), 9000)
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: clamped, tint: 0)
            var gains = device.deviceWhiteBalanceGains(for: values)

            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), maxGain)
            gains.greenGain = min(max(gains.greenGain, 1), maxGain)
            gains.blueGain = min(max(gains.blueGain, 1), maxGain)

            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            device.unlockForConfiguration()

            DispatchQueue.main.async {
                self.whiteBalanceTemperature = clamped
                self.manualWhiteBalance = true
            }
        }
    }

    func setWhiteBalanceAuto() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.manualWhiteBalance = false }
        }
    }

    /// 手动对焦：lensPosition 0（近）… 1（远）
    func setManualFocus(_ value: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            guard (try? device.lockForConfiguration()) != nil else { return }

            let clamped = min(max(value, 0), 1)
            device.setFocusModeLocked(lensPosition: clamped, completionHandler: nil)
            device.unlockForConfiguration()

            DispatchQueue.main.async {
                self.lensPosition = clamped
                self.manualFocus = true
            }
        }
    }

    func setFocusAuto() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.manualFocus = false }
        }
    }

    // MARK: - LUT

    func setLUT(_ lut: LUT3D?, enabled: Bool, intensity: Double) {
        filterLock.lock()
        if enabled, let lut {
            activeFilter = lut.makeFilter(intensity: intensity)
        } else {
            activeFilter = nil
        }
        filterLock.unlock()
    }

    private func snapshotFilter() -> CIFilter? {
        filterLock.lock()
        defer { filterLock.unlock() }
        return activeFilter
    }

    // MARK: - 拍照

    func capturePhoto(
        livePhoto: Bool,
        completion: @escaping (Result<(data: Data, movieURL: URL?), Error>) -> Void
    ) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .quality

            var movieURL: URL?
            if livePhoto, self.photoOutput.isLivePhotoCaptureEnabled {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("live-\(UUID().uuidString).mov")
                settings.livePhotoMovieFileURL = url
                if self.photoOutput.availableLivePhotoVideoCodecTypes.contains(.hevc) {
                    settings.livePhotoVideoCodecType = .hevc
                }
                movieURL = url
            }

            let delegate = PhotoCaptureDelegate(movieURL: movieURL) { [weak self] data, movie, error in
                self?.activeDelegate = nil
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let data else {
                    completion(.failure(CaptureError.noData))
                    return
                }
                completion(.success((data: data, movieURL: movie)))
            }

            self.activeDelegate = delegate
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }
}

// MARK: - 预览帧

extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if !didReportFrameSize {
            didReportFrameSize = true
            let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
            let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
            if width > 0, height > 0 {
                DispatchQueue.main.async { self.frameAspect = width / height }
            }
        }

        var image = CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: LUT3D.sRGB])

        // 留一份未套 LUT 的快照给缩略图用
        let now = Date().timeIntervalSinceReferenceDate
        if now - lastSnapshotAt > 0.8 {
            lastSnapshotAt = now
            snapshotLock.lock()
            snapshot = image
            snapshotLock.unlock()
        }

        if let filter = snapshotFilter() {
            filter.setValue(image, forKey: kCIInputImageKey)
            if let out = filter.outputImage {
                image = out
            }
        }

        renderer?.submit(image)
    }
}

// MARK: - 拍照代理

final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let movieURL: URL?
    private let completion: (Data?, URL?, Error?) -> Void

    private var photoData: Data?
    private var finished = false

    init(movieURL: URL?, completion: @escaping (Data?, URL?, Error?) -> Void) {
        self.movieURL = movieURL
        self.completion = completion
    }

    private func finish(_ data: Data?, _ movie: URL?, _ error: Error?) {
        guard !finished else { return }
        finished = true
        completion(data, movie, error)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            finish(nil, nil, error)
            return
        }
        photoData = photo.fileDataRepresentation()
        if movieURL == nil {
            finish(photoData, nil, nil)
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL?,
        duration: CMTime,
        photoDisplayTime: CMTime,
        resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        if let error {
            finish(nil, nil, error)
            return
        }
        finish(photoData, outputFileURL, nil)
    }
}
