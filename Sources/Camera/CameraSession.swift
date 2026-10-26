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
        case .noDevice: return "找不到后置摄像头"
        case .movieFailed: return "实况照片视频处理失败"
        }
    }
}

struct LensOption: Identifiable, Hashable {
    let type: AVCaptureDevice.DeviceType
    let label: String
    /// 该镜头的原生等效焦段（0.5 / 1 / 3）
    let base: CGFloat

    var id: String { label }
}

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
    private var pendingLensWork: DispatchWorkItem?

    private let filterLock = NSLock()
    private var activeFilter: CIFilter?

    weak var renderer: PreviewRenderer?

    @Published var isConfigured = false
    @Published var livePhotoSupported = false
    @Published var livePhotoEnabled = false
    @Published var errorMessage: String?

    @Published var lenses: [LensOption] = []
    @Published var currentLensType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera
    @Published var virtualZoom: CGFloat = 1

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

        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
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
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        applyPortraitRotation()
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

        let discovered = discoverLenses()

        DispatchQueue.main.async {
            self.lenses = discovered
            self.currentLensType = .builtInWideAngleCamera
            self.virtualZoom = 1
            self.isConfigured = true
        }
    }

    /// 实况支持必须在会话真正跑起来之后才准确
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

    private func applyPortraitRotation() {
        if let conn = videoOutput.connection(with: .video), conn.isVideoRotationAngleSupported(90) {
            conn.videoRotationAngle = 90
        }
        if let conn = photoOutput.connection(with: .video), conn.isVideoRotationAngleSupported(90) {
            conn.videoRotationAngle = 90
        }
    }

    private func discoverLenses() -> [LensOption] {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera,
            .builtInWideAngleCamera,
            .builtInTelephotoCamera
        ]
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .back
        ).devices

        let options = devices.compactMap { dev -> LensOption? in
            switch dev.deviceType {
            case .builtInUltraWideCamera: return LensOption(type: dev.deviceType, label: "0.5×", base: 0.5)
            case .builtInWideAngleCamera: return LensOption(type: dev.deviceType, label: "1×", base: 1)
            case .builtInTelephotoCamera: return LensOption(type: dev.deviceType, label: "3×", base: 3)
            default: return nil
            }
        }

        return options.sorted { $0.base < $1.base }
    }

    deinit {
        if let startObserver {
            NotificationCenter.default.removeObserver(startObserver)
        }
    }

    // MARK: - 变焦（统一用「虚拟焦段」驱动）

    /// 虚拟焦段：0.5 表示超广角，1 表示主摄，3 表示长焦。
    /// 跨越阈值时自动切换物理镜头，和原生相机的手感一致。
    func setVirtualZoom(_ value: CGFloat, animated: Bool = false) {
        let vz = max(0.5, min(value, maxVirtualZoom))

        DispatchQueue.main.async {
            if abs(self.virtualZoom - vz) > 0.001 {
                self.virtualZoom = vz
            }
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let target = self.lensFor(vz) else { return }

            if target.type != self.currentLensType {
                if animated {
                    // 点镜头按钮是明确意图，立刻切
                    self.pendingLensWork?.cancel()
                    self.pendingLensWork = nil
                    self.applyLens(target, virtualZoom: vz)
                } else {
                    // 切镜头要重建采集会话，拖动中立刻切会顿一下。
                    // 延迟 120ms，手指停在同一档位才真正切，拖过去的过程就顺了。
                    self.scheduleLensSwitch(target, virtualZoom: vz)
                }
            } else {
                self.pendingLensWork?.cancel()
                self.pendingLensWork = nil
                self.applyDeviceZoom(vz, base: target.base, animated: animated)
            }
        }
    }

    private func scheduleLensSwitch(_ lens: LensOption, virtualZoom vz: CGFloat) {
        pendingLensWork?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard lens.type != self.currentLensType else { return }
            self.applyLens(lens, virtualZoom: vz)
        }
        pendingLensWork = work
        sessionQueue.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func lensFor(_ vz: CGFloat) -> LensOption? {
        guard !lenses.isEmpty else { return nil }

        // 阈值带一点迟滞，避免在边界上反复切镜头
        if vz < 0.95, let uw = lenses.first(where: { $0.type == .builtInUltraWideCamera }) {
            return uw
        }
        if vz >= 2.9, let tele = lenses.first(where: { $0.type == .builtInTelephotoCamera }) {
            return tele
        }
        return lenses.first(where: { $0.type == .builtInWideAngleCamera }) ?? lenses.first
    }

    private func applyDeviceZoom(_ vz: CGFloat, base: CGFloat, animated: Bool) {
        guard let device else { return }
        guard (try? device.lockForConfiguration()) != nil else { return }

        let maxFactor = min(device.activeFormat.videoMaxZoomFactor, 15)
        let factor = max(1, min(vz / base, maxFactor))

        if animated {
            device.ramp(toVideoZoomFactor: factor, withRate: 10)
        } else {
            device.videoZoomFactor = factor
        }
        device.unlockForConfiguration()
    }

    private func applyLens(_ lens: LensOption, virtualZoom vz: CGFloat) {
        guard let newDevice = AVCaptureDevice.default(lens.type, for: .video, position: .back),
              let newInput = try? AVCaptureDeviceInput(device: newDevice) else { return }

        session.beginConfiguration()
        if let current = videoInput { session.removeInput(current) }

        guard session.canAddInput(newInput) else {
            if let current = videoInput { session.addInput(current) }
            session.commitConfiguration()
            return
        }

        session.addInput(newInput)
        videoInput = newInput
        device = newDevice
        applyPortraitRotation()
        session.commitConfiguration()

        if (try? newDevice.lockForConfiguration()) != nil {
            let maxFactor = min(newDevice.activeFormat.videoMaxZoomFactor, 15)
            let factor = max(1, min(vz / lens.base, maxFactor))
            newDevice.videoZoomFactor = factor
            newDevice.unlockForConfiguration()
        }

        DispatchQueue.main.async {
            self.currentLensType = lens.type
        }

        refreshLivePhotoSupport()
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
            settings.photoQualityPrioritization = .balanced

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

        // 明确声明 sRGB，和成片管线保持一致
        var image = CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: LUT3D.sRGB])

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
