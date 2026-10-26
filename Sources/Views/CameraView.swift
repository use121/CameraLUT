import SwiftUI
import AVFoundation

struct CameraView: View {
    @StateObject private var model = CameraModel()

    @State private var showSettings = false
    @State private var showGallery = false
    @State private var baseZoom: CGFloat = 1
    @State private var lastThumb: UIImage?

    @Namespace private var lensNS

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MetalPreview(renderer: model.renderer)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // 手势层：放在预览之上、控件之下，捏合变焦不会被 MTKView 吞掉
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .gesture(zoomGesture)

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                Spacer()

                zoomControl
                    .padding(.bottom, 12)

                lensBar
                    .padding(.bottom, 16)

                bottomBar
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
            }

            toastLayer
            errorLayer
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(model: model)
        }
        .sheet(isPresented: $showGallery) {
            GalleryView(model: model)
        }
        .onAppear {
            requestAndStart()
            lastThumb = model.lastCapture.flatMap { CaptureStore.shared.thumbnail(for: $0, maxSize: 160) }
        }
        .onDisappear { model.stop() }
        .onChange(of: model.currentLensType) { _, _ in
            baseZoom = 1
        }
        .onChange(of: model.lastCapture) { _, item in
            lastThumb = item.flatMap { CaptureStore.shared.thumbnail(for: $0, maxSize: 160) }
        }
    }

    // MARK: - 浮层

    @ViewBuilder
    private var toastLayer: some View {
        if let toast = model.toast {
            VStack {
                Text(toast)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
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
                    .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 30)
                    .padding(.bottom, 210)
                    .onTapGesture { model.errorText = nil }
            }
        }
    }

    // MARK: - 变焦手势

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                model.setZoom(baseZoom * value.magnification)
            }
            .onEnded { value in
                baseZoom = max(1, min(baseZoom * value.magnification, 15))
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
                        .fill(model.lutEnabled ? Color.green : Color.white.opacity(0.35))
                        .frame(width: 7, height: 7)
                    Text(model.lutEnabled ? model.selectedDisplayName : "LUT 已关闭")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

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
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(.white.opacity(0.28), lineWidth: 0.8)
                }
            }
            .buttonStyle(.plain)

            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 变焦条

    @ViewBuilder
    private var zoomControl: some View {
        if model.zoomFactor > 1.05 {
            HStack(spacing: 10) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))

                Slider(
                    value: Binding(
                        get: { Double(model.zoomFactor) },
                        set: { model.setZoom(CGFloat($0)) }
                    ),
                    in: 1...15
                )
                .tint(.yellow)

                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))

                Text(model.zoomLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.yellow)
                    .frame(width: 38, alignment: .trailing)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.horizontal, 40)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.zoomFactor > 1.05)
        }
    }

    // MARK: - 镜头

    @ViewBuilder
    private var lensBar: some View {
        if model.lenses.count > 1 {
            HStack(spacing: 6) {
                ForEach(model.lenses) { lens in
                    let active = model.currentLensType == lens.type

                    Button {
                        baseZoom = 1
                        model.switchLens(lens.type)
                    } label: {
                        Text(lens.label)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(active ? Color.black : Color.white)
                            .frame(width: 46, height: 30)
                            .background {
                                if active {
                                    Capsule()
                                        .fill(.yellow)
                                        .matchedGeometryEffect(id: "lensHighlight", in: lensNS)
                                } else {
                                    Capsule()
                                        .fill(.ultraThinMaterial)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.72), value: model.currentLensType)
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
                .foregroundStyle(model.livePhotoEnabled ? Color.yellow : Color.white.opacity(0.6))
                .frame(width: 54, height: 54)
                .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!model.livePhotoSupported)
            .opacity(model.livePhotoSupported ? 1 : 0.35)

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
                .foregroundStyle(model.lutEnabled ? Color.green : Color.white.opacity(0.6))
                .frame(width: 54, height: 54)
                .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
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
