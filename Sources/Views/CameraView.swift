import SwiftUI
import AVFoundation

struct CameraView: View {
    @StateObject private var model = CameraModel()

    @State private var showSettings = false
    @State private var showGallery = false
    @State private var lastThumb: UIImage?

    // 手势基准
    @State private var pinchBase: CGFloat = 1
    @State private var lensDragBase: CGFloat?

    // 对焦 / 曝光
    @State private var reticle: CGPoint?
    @State private var showExposure = false
    @State private var hideTask: Task<Void, Never>?

    @Namespace private var lensNS
    @Namespace private var glassNS

    private var minZoom: CGFloat { model.lenses.first?.base ?? 1 }
    private let maxZoom: CGFloat = 15

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                MetalPreview(renderer: model.renderer)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                // 手势层：预览之上、控件之下
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(pinchGesture)
                    .simultaneousGesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                handleTap(at: value.location, in: geo.size)
                            }
                    )

                reticleLayer

                VStack(spacing: 0) {
                    topBar
                        .padding(.horizontal, 16)
                        .padding(.top, 54)

                    Spacer()

                    exposureControl
                    zoomControl
                    lensBar
                        .padding(.top, 12)
                        .padding(.bottom, 16)

                    bottomBar
                        .padding(.horizontal, 24)
                        .padding(.bottom, 38)
                }

                toastLayer
                errorLayer
            }
        }
        .ignoresSafeArea()
        .sheet(isPresented: $showSettings) {
            SettingsSheet(model: model)
        }
        .sheet(isPresented: $showGallery) {
            GalleryView(model: model)
        }
        .onAppear {
            requestAndStart()
            pinchBase = model.virtualZoom
            lastThumb = model.lastCapture.flatMap { CaptureStore.shared.thumbnail(for: $0, maxSize: 160) }
        }
        .onDisappear {
            model.stop()
            hideTask?.cancel()
        }
        .onChange(of: model.lastCapture) { _, item in
            lastThumb = item.flatMap { CaptureStore.shared.thumbnail(for: $0, maxSize: 160) }
        }
    }

    // MARK: - 对焦

    @ViewBuilder
    private var reticleLayer: some View {
        if let point = reticle {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.yellow, lineWidth: 1.6)
                .frame(width: 76, height: 76)
                .position(point)
                .allowsHitTesting(false)
                .transition(.scale(scale: 1.35).combined(with: .opacity))
        }
    }

    private func handleTap(at location: CGPoint, in size: CGSize) {
        let devicePoint = devicePoint(from: location, in: size)
        model.focus(at: devicePoint)

        withAnimation(.spring(response: 0.26, dampingFraction: 0.66)) {
            reticle = location
            showExposure = true
        }

        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) {
                    reticle = nil
                    showExposure = false
                }
            }
        }
    }

    /// 屏幕点 → 设备坐标。
    /// 画面按 aspect-fill 铺满，先还原成画面内归一化坐标；
    /// 视频旋转了 90°，设备 (0,0) 落在竖屏画面的右上角，所以要做一次转置。
    private func devicePoint(from location: CGPoint, in size: CGSize) -> CGPoint {
        let aspect = model.frameAspect
        guard size.width > 0, size.height > 0, aspect > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }

        let viewAspect = size.width / size.height
        var u: CGFloat
        var v: CGFloat

        if aspect > viewAspect {
            let displayedWidth = size.height * aspect
            let offsetX = (size.width - displayedWidth) / 2
            u = (location.x - offsetX) / displayedWidth
            v = location.y / size.height
        } else {
            let displayedHeight = size.width / aspect
            let offsetY = (size.height - displayedHeight) / 2
            u = location.x / size.width
            v = (location.y - offsetY) / displayedHeight
        }

        u = min(max(u, 0), 1)
        v = min(max(v, 0), 1)

        return CGPoint(x: v, y: 1 - u)
    }

    // MARK: - 浮层

    @ViewBuilder
    private var toastLayer: some View {
        if let toast = model.toast {
            VStack {
                Text(toast)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                Spacer()
            }
            .padding(.top, 92)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var errorLayer: some View {
        if let error = model.errorText {
            VStack {
                Spacer()
                Text(error)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(14)
                    .glassEffect(.regular.tint(.red.opacity(0.55)), in: .rect(cornerRadius: 16))
                    .padding(.horizontal, 30)
                    .padding(.bottom, 210)
                    .onTapGesture { model.errorText = nil }
            }
        }
    }

    // MARK: - 手势

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                model.setVirtualZoom(pinchBase * value.magnification)
            }
            .onEnded { value in
                pinchBase = max(minZoom, min(pinchBase * value.magnification, maxZoom))
            }
    }

    private var lensDragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if lensDragBase == nil { lensDragBase = model.virtualZoom }
                guard let base = lensDragBase else { return }
                let factor = pow(2.0, Double(value.translation.width) / 140.0)
                model.setVirtualZoom(CGFloat(Double(base) * factor))
            }
            .onEnded { _ in
                lensDragBase = nil
                pinchBase = model.virtualZoom
            }
    }

    // MARK: - 顶部

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                model.lutEnabled.toggle()
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(model.lutEnabled ? Color.green : Color.white.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text(model.lutEnabled ? model.selectedDisplayName : "LUT 已关闭")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .lineLimit(1)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: .capsule)

            Spacer()

            Button {
                showGallery = true
            } label: {
                ZStack {
                    if let lastThumb {
                        Image(uiImage: lastThumb)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: .rect(cornerRadius: 11))

            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: Circle())
        }
    }

    // MARK: - 曝光

    @ViewBuilder
    private var exposureControl: some View {
        if showExposure {
            HStack(spacing: 10) {
                Image(systemName: "sun.min")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { Double(model.exposureBias) },
                        set: { model.setExposureBias(Float($0)) }
                    ),
                    in: Double(model.exposureRange.lowerBound)...Double(model.exposureRange.upperBound)
                )
                .tint(.yellow)
                .frame(width: 150)

                Image(systemName: "sun.max.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.yellow)

                Text(model.exposureLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    // MARK: - 变焦条

    @ViewBuilder
    private var zoomControl: some View {
        if abs(model.virtualZoom - 1) > 0.05 {
            HStack(spacing: 10) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { log2(Double(max(model.virtualZoom, minZoom))) },
                        set: { model.setVirtualZoom(CGFloat(pow(2, $0))) }
                    ),
                    in: log2(Double(minZoom))...log2(Double(maxZoom))
                )
                .tint(.yellow)

                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(model.zoomLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.yellow)
                    .frame(width: 42, alignment: .trailing)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 40)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: abs(model.virtualZoom - 1) > 0.05)
        }
    }

    // MARK: - 镜头

    @ViewBuilder
    private var lensBar: some View {
        if model.lenses.count > 1 {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(model.lenses) { lens in
                        let active = abs(lens.base - model.activeLensBase) < 0.01

                        Button {
                            pinchBase = lens.base
                            model.selectLens(lens)
                        } label: {
                            Text(lens.label)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(active ? Color.black : Color.primary)
                                .frame(width: 46, height: 30)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(
                            active
                                ? .regular.tint(.yellow.opacity(0.85)).interactive()
                                : .regular,
                            in: .capsule
                        )
                    }
                }
                .animation(.spring(response: 0.42, dampingFraction: 0.72), value: model.activeLensBase)
                .gesture(lensDragGesture)
            }
        }
    }

    // MARK: - 底部

    private var bottomBar: some View {
        HStack(alignment: .center) {
            Button {
                model.livePhotoEnabled.toggle()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: model.livePhotoEnabled ? "livephoto" : "livephoto.slash")
                        .font(.system(size: 17, weight: .medium))
                    Text("实况")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                }
                .foregroundStyle(model.livePhotoEnabled ? Color.yellow : Color.primary)
                .frame(width: 54, height: 54)
            }
            .buttonStyle(.plain)
            .glassEffect(
                .regular.tint(model.livePhotoEnabled ? .yellow.opacity(0.3) : .clear).interactive(),
                in: Circle()
            )

            Spacer()

            Button {
                model.capture()
            } label: {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.85), lineWidth: 4)
                        .frame(width: 78, height: 78)
                    Circle()
                        .fill(model.isCapturing ? Color.white.opacity(0.35) : Color.white)
                        .frame(width: 63, height: 63)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.isCapturing)
            .scaleEffect(model.isCapturing ? 0.94 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: model.isCapturing)

            Spacer()

            Button {
                model.lutEnabled.toggle()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "camera.filters")
                        .font(.system(size: 17, weight: .medium))
                    Text(model.lutEnabled ? "开" : "关")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                }
                .foregroundStyle(model.lutEnabled ? Color.green : Color.primary)
                .frame(width: 54, height: 54)
            }
            .buttonStyle(.plain)
            .glassEffect(
                .regular.tint(model.lutEnabled ? .green.opacity(0.28) : .clear).interactive(),
                in: Circle()
            )
        }
    }

    // MARK: - 权限

    private func requestAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            model.start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        model.start()
                    } else {
                        model.errorText = "没有相机权限，请到设置里打开"
                    }
                }
            }
        default:
            model.errorText = "没有相机权限，请到设置里打开"
        }
    }
}
