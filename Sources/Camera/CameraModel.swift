import Foundation
import Combine
import UIKit
import AVFoundation

struct LUTInfo: Identifiable, Equatable {
    let id: String        // 文件名
    let name: String      // 显示名
    let detail: String    // "3D · 33³" / "解析失败"
    let ok: Bool
}

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

    // MARK: - LUT

    @Published var lutFiles: [String] = []
    @Published var lutInfos: [LUTInfo] = []
    @Published var selectedFile: String?
    @Published var selectedName: String = "无 LUT"

    @Published var lutEnabled: Bool = true {
        didSet { applyLUT() }
    }

    /// 0...1，LUT 作用强度
    @Published var lutIntensity: Double = 1.0 {
        didSet {
            guard abs(oldValue - lutIntensity) > 0.001 else { return }
            applyLUT()
        }
    }

    // MARK: - 实况

    @Published var livePhotoEnabled: Bool = false
    @Published var livePhotoSupported: Bool = false
    @Published var livePhotoArmed: Bool = false
    @Published var livePhotoLUTMode: LivePhotoLUTMode = .staticOnly

    // MARK: - 镜头与变焦

    @Published var lenses: [LensOption] = []
    @Published var currentLensType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera
    @Published var virtualZoom: CGFloat = 1

    // MARK: - 拍照与图库

    @Published var captures: [CaptureItem] = []
    @Published var lastCapture: CaptureItem?

    @Published var isCapturing = false
    @Published var toast: String?
    @Published var errorText: String?
    @Published var lastSaveInfo: String = "—"

    private var currentLUT: LUT3D?
    private var cancellables = Set<AnyCancellable>()

    init() {
        session.renderer = renderer

        session.$livePhotoSupported
            .receive(on: DispatchQueue.main)
            .assign(to: &$livePhotoSupported)

        session.$livePhotoEnabled
            .receive(on: DispatchQueue.main)
            .assign(to: &$livePhotoArmed)

        session.$errorMessage
            .receive(on: DispatchQueue.main)
            .assign(to: &$errorText)

        session.$lenses
            .receive(on: DispatchQueue.main)
            .assign(to: &$lenses)

        session.$currentLensType
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentLensType)

        session.$virtualZoom
            .receive(on: DispatchQueue.main)
            .assign(to: &$virtualZoom)

        captures = CaptureStore.shared.items()
        lastCapture = captures.first

        selectedFile = LUTStore.shared.selectedFileName
        refreshLUTs()
        applyLUT()
    }

    // MARK: - LUT 管理

    func refreshLUTs() {
        let files = LUTStore.shared.listFiles()
        lutFiles = files

        DispatchQueue.global(qos: .userInitiated).async {
            var infos: [LUTInfo] = []
            for file in files {
                if let lut = LUTStore.shared.load(fileName: file) {
                    infos.append(LUTInfo(
                        id: file,
                        name: lut.name,
                        detail: "\(lut.source) · \(lut.dimension)³",
                        ok: true
                    ))
                } else {
                    let quick = LUTStore.shared.quickInfo(fileName: file)
                    infos.append(LUTInfo(
                        id: file,
                        name: quick?.title ?? file,
                        detail: "解析失败",
                        ok: false
                    ))
                }
            }
            DispatchQueue.main.async {
                self.lutInfos = infos
            }
        }
    }

    func select(_ file: String?) {
        selectedFile = file
        LUTStore.shared.selectedFileName = file
        applyLUT()
    }

    func applyLUT() {
        guard let file = selectedFile else {
            currentLUT = nil
            selectedName = "无 LUT"
            session.setLUT(nil, enabled: false, intensity: lutIntensity)
            return
        }

        guard let lut = LUTStore.shared.load(fileName: file) else {
            currentLUT = nil
            selectedName = file
            session.setLUT(nil, enabled: false, intensity: lutIntensity)
            errorText = "这个 LUT 解析失败，可能不是标准 .cube 文件：\(file)"
            return
        }

        currentLUT = lut
        selectedName = lut.name
        session.setLUT(lut, enabled: lutEnabled, intensity: lutIntensity)
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

    var selectedDisplayName: String { selectedName }

    // MARK: - 镜头与变焦

    func setVirtualZoom(_ value: CGFloat, animated: Bool = false) {
        session.setVirtualZoom(value, animated: animated)
    }

    func selectLens(_ lens: LensOption) {
        session.setVirtualZoom(lens.base, animated: true)
    }

    var zoomLabel: String {
        String(format: "%.1f×", Double(virtualZoom))
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
        let intensity = lutIntensity
        let mode = livePhotoLUTMode

        session.capturePhoto(livePhoto: wantLive) { [weak self] result in
            guard let self else { return }

            switch result {
            case .failure(let error):
                self.finish("拍摄失败：\(error.localizedDescription)", success: false)

            case .success(let payload):
                let isLive = payload.movieURL != nil
                let processed = PhotoSaver.applyLUT(
                    to: payload.data,
                    lut: lut,
                    intensity: intensity,
                    preserveFormat: isLive
                )

                guard let movieURL = payload.movieURL else {
                    PhotoSaver.save(photoData: processed, movieURL: nil) { result in
                        self.handle(result, photoData: processed, movie: nil)
                    }
                    return
                }

                if mode == .perFrame, let lut {
                    let output = FileManager.default.temporaryDirectory
                        .appendingPathComponent("lut-\(UUID().uuidString).mov")
                    MovieLUTRenderer.render(input: movieURL, output: output, lut: lut, intensity: intensity) { newURL in
                        let finalMovie = newURL ?? movieURL
                        PhotoSaver.save(photoData: processed, movieURL: finalMovie) { result in
                            self.handle(result, photoData: processed, movie: finalMovie)
                        }
                    }
                } else {
                    PhotoSaver.save(photoData: processed, movieURL: movieURL) { result in
                        self.handle(result, photoData: processed, movie: movieURL)
                    }
                }
            }
        }
    }

    private func handle(_ result: PhotoSaver.SaveResult, photoData: Data, movie: URL?) {
        switch result {
        case .livePhoto:
            persist(photoData: photoData, movieURL: movie)
            setSaveInfo("实况照片")
            finish("已保存实况照片", success: true)

        case .plainPhoto:
            persist(photoData: photoData, movieURL: nil)
            setSaveInfo("普通照片（实况配对失败）")
            finish("实况配对失败，已存为普通照片", success: true)

        case .failed(let error):
            setSaveInfo("失败：\(error?.localizedDescription ?? "未知")")
            finish("保存失败：\(error?.localizedDescription ?? "未知错误")", success: false)
        }
    }

    private func setSaveInfo(_ text: String) {
        DispatchQueue.main.async { self.lastSaveInfo = text }
    }

    private func persist(photoData: Data, movieURL: URL?) {        guard let item = CaptureStore.shared.save(photoData: photoData, movieURL: movieURL) else { return }
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
