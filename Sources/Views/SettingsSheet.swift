import SwiftUI
import UniformTypeIdentifiers

struct SettingsSheet: View {
    @ObservedObject var model: CameraModel
    @Environment(\.dismiss) private var dismiss

    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            Form {
                lutSection
                liveSection
                helpSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    model.importLUT(from: url)
                case .failure(let error):
                    model.errorText = "选择文件失败：\(error.localizedDescription)"
                }
            }
            .alert("提示", isPresented: Binding(
                get: { model.errorText != nil },
                set: { if !$0 { model.errorText = nil } }
            )) {
                Button("好") { model.errorText = nil }
            } message: {
                Text(model.errorText ?? "")
            }
        }
    }

    // MARK: - LUT

    private var lutSection: some View {
        Section {
            if model.lutFiles.isEmpty {
                Text("还没有导入 LUT")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.lutFiles, id: \.self) { file in
                    Button {
                        model.select(file)
                    } label: {
                        HStack {
                            Text(displayName(file))
                                .foregroundStyle(.primary)
                            Spacer()
                            if model.selectedFile == file {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        model.deleteLUT(model.lutFiles[index])
                    }
                }
            }

            Button {
                showImporter = true
            } label: {
                Label("导入 .cube 文件", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("LUT")
        } footer: {
            Text("把 .cube 文件存到「文件」App 里，然后从这里导入。导入后会复制一份到 App 内。")
        }
    }

    // MARK: - 实况

    private var liveSection: some View {
        Section {
            Toggle("拍摄实况照片", isOn: $model.livePhotoEnabled)
                .disabled(!model.livePhotoSupported)

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
            if !model.livePhotoSupported {
                Text("当前设备不支持实况照片拍摄。")
            } else {
                Text("实况照片 = 一张静态图 + 一段短视频。切换应用范围会立刻生效，下次拍摄就用新设置。")
            }
        }
    }

    // MARK: - 说明

    private var helpSection: some View {
        Section("说明") {
            Text("· 预览和成片都按当前 LUT 处理，所见即所得。")
            Text("· 关掉 LUT 开关就是原始色彩。")
            Text("· 逐帧套 LUT 会明显发热，建议拍完歇一会儿。")
        }
        .font(.footnote)
    }

    private func displayName(_ file: String) -> String {
        if file.lowercased().hasSuffix(".cube") {
            return String(file.dropLast(5))
        }
        return file
    }
}
