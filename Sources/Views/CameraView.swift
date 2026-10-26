import SwiftUI
import AVFoundation

struct CameraView: View {
    @StateObject private var model = CameraModel()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MetalPreview(renderer: model.renderer)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 18)
                    .padding(.top, 8)

                Spacer()

                bottomBar
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
            }

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
                .padding(.top, 90)
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if let error = model.errorText {
                VStack {
                    Spacer()
                    Text(error)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(14)
                        .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 30)
                        .padding(.bottom, 160)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(model: model)
        }
        .onAppear(perform: requestAndStart)
        .onDisappear { model.stop() }
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

    // MARK: - 底部

    private var bottomBar: some View {
        HStack(alignment: .center) {
            // 实况开关
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

            // 快门
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

            Spacer()

            // LUT 开关
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
