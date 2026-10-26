import SwiftUI

struct SettingsSheet: View {
    @ObservedObject var model: CameraModel
    @Binding var showImporter: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                lutSection
                intensitySection
                liveSection
                helpSection
                debugSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: - LUT

    private var lutSection: some View {
        Section {
            if model.lutInfos.isEmpty {
                Text("还没有导入 LUT")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.lutInfos) { info in
                    Button {
                        model.select(info.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(info.name)
                                    .foregroundStyle(info.ok ? .primary : .secondary)
                                Text(info.detail)
                                    .font(.caption2)
                                    .foregroundStyle(info.ok ? Color.secondary : Color.red)
                            }
                            Spacer()
                            if model.selectedFile == info.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        model.deleteLUT(model.lutInfos[index].id)
                    }
                }
            }

            Button {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    showImporter = true
                }
            } label: {
                Label("导入 .cube 文件", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("LUT")
        } footer: {
            Text("把 .cube 存到「文件」App 再从这里导入。3D 和 1D 都支持，1D 会自动转成 3D。")
        }
    }

    // MARK: - 强度

    private var intensitySection: some View {
        Section {
            HStack {
                Text("强度")
                Spacer()
                Text("\(Int((model.lutIntensity * 100).rounded()))%")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Slider(value: $model.lutIntensity, in: 0...1)
                .tint(.yellow)

            HStack(spacing: 8) {
                quickButton("原始", 0)
                quickButton("25%", 0.25)
                quickButton("50%", 0.5)
                quickButton("75%", 0.75)
                quickButton("全量", 1)
            }
            .padding(.vertical, 2)
        } header: {
            Text("LUT 强度")
        } footer: {
            Text("0% 等于不套 LUT，100% 是全量。往中间调可以保留更多原始色彩。")
        }
    }

    private func quickButton(_ title: String, _ value: Double) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                model.lutIntensity = value
            }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(abs(model.lutIntensity - value) < 0.01 ? Color.yellow.opacity(0.35) : Color.secondary.opacity(0.12))
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 实况

    private var liveSection: some View {
        Section {
            Toggle("拍摄实况照片", isOn: $model.livePhotoEnabled)

            HStack {
                Text("设备支持")
                Spacer()
                Text(model.livePhotoSupported ? "支持" : "不支持")
                    .foregroundStyle(model.livePhotoSupported ? .green : .red)
            }
            .font(.footnote)

            HStack {
                Text("拍摄通道")
                Spacer()
                Text(model.livePhotoArmed ? "已就绪" : "未就绪")
                    .foregroundStyle(model.livePhotoArmed ? .green : .orange)
            }
            .font(.footnote)

            Picker("LUT 应用范围", selection: $model.livePhotoLUTMode) {
                ForEach(CameraModel.LivePhotoLUTMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            Text(model.livePhotoLUTMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("实况照片")
        } footer: {
            Text("实况照片 = 一张静态图 + 一段短视频。")
        }
    }

    // MARK: - 说明

    private var helpSection: some View {
        Section("说明") {
            Text("· 预览和成片走同一条色彩管线，所见即所得。")
            Text("· 关掉 LUT 开关就是原始色彩。")
            Text("· 逐帧套 LUT 会明显发热，建议拍完歇一会儿。")
        }
        .font(.footnote)
    }

    private var debugSection: some View {
        Section("诊断") {
            HStack {
                Text("上次保存")
                Spacer()
                Text(model.lastSaveInfo)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.footnote)

            VStack(alignment: .leading, spacing: 3) {
                Text("镜头探测")
                    .font(.footnote)
                Text(model.lensDebug.isEmpty ? "—" : model.lensDebug)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}
