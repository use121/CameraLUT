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

    var id: String { label }
}

/// 只负责采集：会话配置、镜头切换、变焦、预览帧、拍照。
final class CameraSession: NSObject, ObservableObject {
    let session = AVCaptureSession()
    let photoOutput = AVCapturePhotoOutput()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "cam.session")
    private let videoQueue = DispatchQueue(label: "cam.video")

    private var device: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var activeDelegate: PhotoCaptureDelegate?

    private let filterLock = NSLock()
    private var activeFilter: CIFilter?
    private(set) var currentLUT: LUT3D?

    weak var renderer: PreviewRenderer?

    @Published var isConfigured = false
    @Published var livePhotoSupported = false
    @Published var errorMessage: String?

    @Published var lenses: [LensOption] = []
    @Published var currentLensType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera
    @Published var zoomFactor: CGFloat = 1

    // MARK: - 生命周期

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured { self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
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
        session.sessionPreset = .high

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
            if photoOutput.isLivePhotoCaptureSupported {
                photoOutput.isLivePhotoCaptureEnabled = true
            }
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        applyPortraitRotation()
        session.commitConfiguration()

        let discovered = discoverLenses()

        DispatchQueue.main.async {
            self.lenses = discovered
            self.currentLensType = .builtInWideAngleCamera
            self.zoomFactor = 1
            self.livePhotoSupported = self.photoOutput.isLivePhotoCaptureSupported
            self.isConfigured = true
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
            case .builtInUltraWideCamera: return LensOption(type: dev.deviceType, label: "0.5×")
            case .builtInWideAngleCamera: return LensOption(type: dev.deviceType, label: "1×")
            case .builtInTelephotoCamera: return LensOption(type: dev.deviceType, label: "3×")
            default: return nil
            }
        }

        return options.sorted { rank($0.type) < rank($1.type) }
    }

    private func rank(_ type: AVCaptureDevice.DeviceType) -> Int {
        switch type {
        case .builtInUltraWideCamera: return 0
        case .builtInWideAngleCamera: return 1
        case .builtInTelephotoCamera: return 2
        default: return 3
        }
    }

    // MARK: - 镜头与变焦

    func switchLens(to type: AVCaptureDevice.DeviceType) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard type != self.currentLensType else { return }
            guard let newDevice = AVCaptureDevice.default(type, for: .video, position: .back) else { return }
            guard let newInput = try? AVCaptureDeviceInput(device: newDevice) else { return }

            self.session.beginConfiguration()
            if let current = self.videoInput { self.session.removeInput(current) }

            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoInput = newInput
                self.device = newDevice
                self.applyPortraitRotation()
                self.session.commitConfiguration()

                DispatchQueue.main.async {
                    self.currentLensType = type
                    self.zoomFactor = 1
                }
            } else {
                if let current = self.videoInput { self.session.addInput(current) }
                self.session.commitConfiguration()
            }
        }
    }

    func setZoom(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            guard (try? device.lockForConfiguration()) != nil else { return }

            let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 15)
            let clamped = max(1, min(factor, maxZoom))
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()

            DispatchQueue.main.async { self.zoomFactor = clamped }
        }
    }

    var currentMaxZoom: CGFloat {
        guard let device else { return 15 }
        return min(device.activeFormat.videoMaxZoomFactor, 15)
    }

    // MARK: - LUT

    func setLUT(_ lut: LUT3D?, enabled: Bool) {
        filterLock.lock()
        currentLUT = lut
        activeFilter = (enabled ? lut?.makeFilter() : nil)
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

            // 用默认格式，不强制指定编码，避免编码器不兼容抛异常
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

        var image = CIImage(cvPixelBuffer: pixelBuffer)

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
