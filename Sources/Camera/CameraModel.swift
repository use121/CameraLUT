import Foundation
import Combine
import UIKit
import AVFoundation

final class CameraModel: ObservableObject {
    enum LivePhotoLUTMode: String, CaseIterable, Identifiable {
        case staticOnly
        case perFrame

        var id: String { rawValue }

        var label: String {
            switch self {
            case .staticOnly: return "只套静态帧"
            case .perFrame: return "视频也逐帧套"
            }
        }

        var detail: String {
            switch self {
            case .staticOnly: return "保存快，但实况播放时会有轻微跳色"
            case .perFrame: return "保存慢 1–3 秒，播放时颜色一致"
            }
        }
    }

    let session = CameraSession()
    let renderer = PreviewRenderer()

    @Published var lutFiles: [String] = []
    @Published var selectedFile: String?
    @Published var lutEnabled: Bool = true {
        didSet { applyLUT() }
    }
    @Published var livePhotoEnabled: Bool = false
    @Published var livePhotoLUTMode: LivePhotoLUTMode = .staticOnly
    @Published var livePhotoSupported: Bool = false

    @Published var lenses: [LensOption] = []
    @Published var currentLensType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera
    @Published var zoomFactor: CGFloat = 1

    @Published var captures: [CaptureItem] = []
    @Published var lastCapture: CaptureItem?

    @Published var isCapturing = false
    @Published var toast: String?
    @Published var errorText: String?

    private var currentLUT: LUT3D?
    private var cancellables = Set<AnyCancellable>()

    init() {
        session.renderer = renderer

        session.$livePhotoSupported
            .receive(on: DispatchQueue.main)
            .assign(to: &$livePhotoSupported)

        session.$errorMessage
            .receive(on: DispatchQueue.main)
            .assign(to: &$errorText)

        session.$lenses
            .receive(on: DispatchQueue.main)
            .assign(to: &$lenses)

        session.$currentLensType
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentLensType)

        session.$zoomFactor
            .receive(on: DispatchQueue.main)
            .assign(to: &$zoomFactor)

        refreshLUTs()
        captures = CaptureStore.shared.items()
        lastCapture = captures.first
        selectedFile = LUTStore.shared.selectedFileName
        applyLUT()
    }

    // MARK: - LUT

    func refreshLUTs() {
        lutFiles = LUTStore.shared.listFiles()
    }

    func select(_ file: String?) {
        selectedFile = file
        LUTStore.shared.selectedFileName = file
        applyLUT()
    }

    func applyLUT() {
        guard let file = selectedFile else {
            currentLUT = nil
            session.setLUT(nil, enabled: false)
            return
        }

        guard let lut = LUTStore.shared.load(fileName: file) else {
            currentLUT = nil
            session.setLUT(nil, enabled: false)
            errorText = "这个 LUT 解析失败，可能不是标准 .cube 文件：\(file)"
            return
        }

        currentLUT = lut
        session.setLUT(lut, enabled: lutEnabled)
    }

    func importLUT(from url: URL) {
        guard url.pathExtension.lowercased() == "cube" else {
            errorText = "请选择 .cube 格式的 LUT 文件"
            return
        }
        do {
            let name = try LUTStore.shared.importFile(from: url)
            refreshLUTs()
            select(name)
            showToast("已导入 \(name)")
        } catch {
            errorText = error.localizedDescription
        }
    }

    func deleteLUT(_ file: String) {
        LUTStore.shared.delete(fileName: file)
        if selectedFile == file {
            selectedFile = nil
            applyLUT()
        }
        refreshLUTs()
    }

    var selectedDisplayName: String {
        guard let file = selectedFile else { return "无 LUT" }
        return LUTStore.shared.load(fileName: file)?.name ?? file
    }

    var selectedDetail: String {
        guard let file = selectedFile, let lut = LUTStore.shared.load(fileName: file) else {
            return "未选择"
        }
        return "\(lut.source) · \(lut.dimension)³"
    }

    // MARK: - 镜头与变焦

    func switchLens(_ type: AVCaptureDevice.DeviceType) {
        session.switchLens(to: type)
    }

    func setZoom(_ factor: CGFloat, animated: Bool = false) {
        session.setZoom(factor, animated: animated)
    }

    var zoomLabel: String {
        String(format: "%.1f×", Double(zoomFactor))
    }

    // MARK: - 生命周期

    func start() { session.start() }
    func stop() { session.stop() }

    // MARK: - 拍照

    func capture() {
        guard !isCapturing else { return }
        isCapturing = true

        let wantLive = livePhotoEnabled && livePhotoSupported
        let lut = lutEnabled ? currentLUT : nil
        let mode = livePhotoLUTMode

        session.capturePhoto(livePhoto: wantLive) { [weak self] result in
            guard let self else { return }

            switch result {
            case .failure(let error):
                self.finish("拍摄失败：\(error.localizedDescription)", success: false)

            case .success(let payload):
                let processed = PhotoSaver.applyLUT(to: payload.data, lut: lut)

                guard let movieURL = payload.movieURL else {
                    PhotoSaver.save(photoData: processed, movieURL: nil) { ok, err in
                        if ok { self.persist(photoData: processed, movieURL: nil) }
                        self.finish(ok ? "已保存" : (err?.localizedDescription ?? "保存失败"), success: ok)
                    }
                    return
                }

                if mode == .perFrame, let lut {
                    let output = FileManager.default.temporaryDirectory
                        .appendingPathComponent("lut-\(UUID().uuidString).mov")
                    MovieLUTRenderer.render(input: movieURL, output: output, lut: lut) { newURL in
                        let finalMovie = newURL ?? movieURL
                        PhotoSaver.save(photoData: processed, movieURL: finalMovie) { ok, err in
                            if ok { self.persist(photoData: processed, movieURL: finalMovie) }
                            self.finish(ok ? "已保存实况照片" : (err?.localizedDescription ?? "保存失败"), success: ok)
                        }
                    }
                } else {
                    PhotoSaver.save(photoData: processed, movieURL: movieURL) { ok, err in
                        if ok { self.persist(photoData: processed, movieURL: movieURL) }
                        self.finish(ok ? "已保存实况照片" : (err?.localizedDescription ?? "保存失败"), success: ok)
                    }
                }
            }
        }
    }

    /// 存一份到 App 内的图库（相册之外），供应用内预览
    private func persist(photoData: Data, movieURL: URL?) {
        guard let item = CaptureStore.shared.save(photoData: photoData, movieURL: movieURL) else { return }
        DispatchQueue.main.async {
            self.lastCapture = item
            self.captures = CaptureStore.shared.items()
        }
    }

    private func finish(_ message: String, success: Bool) {
        DispatchQueue.main.async {
            self.isCapturing = false
            self.toast = message
            UINotificationFeedbackGenerator().notificationOccurred(success ? .success : .error)
            let current = message
            Task {
                try? await Task.sleep(for: .seconds(1.8))
                await MainActor.run {
                    if self.toast == current { self.toast = nil }
                }
            }
        }
    }

    private func showToast(_ message: String) {
        DispatchQueue.main.async {
            self.toast = message
            let current = message
            Task {
                try? await Task.sleep(for: .seconds(1.8))
                await MainActor.run {
                    if self.toast == current { self.toast = nil }
                }
            }
        }
    }
}
