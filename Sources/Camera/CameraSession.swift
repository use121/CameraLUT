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
    /// 等效焦段（0.5 / 1 / 3 …）
    let base: CGFloat
    let label: String

    var id: String { label }
}

/// 采集层。
///
/// 变焦走**虚拟多摄设备**（builtInTripleCamera / DualWideCamera），
/// 由系统在内部完成镜头切换和交叉淡化 —— 全程不重建会话，所以是丝滑的。
/// 早期版本手动 removeInput/addInput 切物理镜头，每次都要重配会话，必然顿挫。
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

    /// 虚拟设备里最广那颗镜头的等效焦段（有超广角就是 0.5）
    private var zoomBase: CGFloat = 1

    private let filterLock = NSLock()
    private var activeFilter: CIFilter?

    weak var renderer: PreviewRenderer?

    @Published var isConfigured = false
    @Published var livePhotoSupported = false
    @Published var livePhotoEnabled = false
    @Published var errorMessage: String?

    @Published var lenses: [LensOption] = []
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

        guard let dev = pickBackDevice() else {
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

        let base = constituentBase(for: dev)
        let options = buildLenses(for: dev, base: base)

        // 起始停在 1×（主摄），虚拟设备用 videoZoomFactor = 1 / base 表示
        if (try? dev.lockForConfiguration()) != nil {
            dev.videoZoomFactor = max(1, 1 / base)
            dev.unlockForConfiguration()
        }

        DispatchQueue.main.async {
            self.zoomBase = base
            self.lenses = options
            self.virtualZoom = 1
            self.isConfigured = true
        }
    }

    /// 优先虚拟多摄设备：一颗设备覆盖全部焦段，系统负责无缝切换
    private func pickBackDevice() -> AVCaptureDevice? {
        let candidates: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera
        ]
        for type in candidates {
            if let dev = AVCaptureDevice.default(type, for: .video, position: .back) {
                return dev
            }
        }
        return nil
    }

    private func constituentBase(for device: AVCaptureDevice) -> CGFloat {
        let hasUltraWide = device.constituentDevices.contains {
            $0.deviceType == .builtInUltraWideCamera
        }
        return hasUltraWide ? 0.5 : 1.0
    }

    private func buildLenses(for device: AVCaptureDevice, base: CGFloat) -> [LensOption] {
        var bases: [CGFloat] = [base]

        for value in device.virtualDeviceSwitchOverVideoZoomFactors {
            bases.append(base * CGFloat(truncating: value))
        }

        var unique: [CGFloat] = []
        for value in bases.sorted() where !unique.contains(where: { abs($0 - value) < 0.01 }) {
            unique.append(value)
        }

        return unique.map { LensOption(base: $0, label: formatZoom($0)) }
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

    private func applyPortraitRotation() {
        if let conn = videoOutput.connection(with: .video), conn.isVideoRotationAngleSupported(90) {
            conn.videoRotationAngle = 90
        }
        if let conn = photoOutput.connection(with: .video), conn.isVideoRotationAngleSupported(90) {
            conn.videoRotationAngle = 90
        }
    }

    deinit {
        if let startObserver {
            NotificationCenter.default.removeObserver(startObserver)
        }
    }

    // MARK: - 变焦

    /// 只改 videoZoomFactor，不碰会话配置。虚拟设备内部自己切镜头 + 交叉淡化。
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
