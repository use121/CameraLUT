import SwiftUI
import CoreImage
import UIKit

struct EditorView: View {
    let item: CaptureItem
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @StateObject private var editor: PhotoEditor

    @State private var tool: Tool = .exposure
    @State private var lutInfos: [LUTInfo] = []
    @State private var saving = false

    enum Tool: String, CaseIterable, Identifiable {
        case exposure, contrast, saturation, temperature, sharpness, vignette, lut

        var id: String { rawValue }

        var label: String {
            switch self {
            case .exposure: return "曝光"
            case .contrast: return "对比"
            case .saturation: return "饱和"
            case .temperature: return "色温"
            case .sharpness: return "锐化"
            case .vignette: return "暗角"
            case .lut: return "LUT"
            }
        }

        var symbol: String {
            switch self {
            case .exposure: return "sun.max"
            case .contrast: return "circle.lefthalf.filled"
            case .saturation: return "drop"
            case .temperature: return "thermometer.medium"
            case .sharpness: return "wand.and.rays"
            case .vignette: return "circle.dashed"
            case .lut: return "camera.filters"
            }
        }
    }

    init(item: CaptureItem, onSaved: @escaping () -> Void = {}) {
        self.item = item
        self.onSaved = onSaved

        let image: CIImage
        if let data = try? Data(contentsOf: item.imageURL), let decoded = CIImage(data: data) {
            image = decoded
        } else {
            image = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1))
                .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        _editor = StateObject(wrappedValue: PhotoEditor(image: image))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                previewArea

                if tool == .lut {
                    lutStrip
                    intensityRow
                } else {
                    sliderRow
                }

                toolRow
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("重置") {
                        editor.reset()
                        editor.refreshPreview()
                    }
                    .disabled(!editor.hasChanges)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                        .disabled(saving)
                }
            }
        }
        .onAppear {
            loadLUTs()
            editor.refreshPreview()
        }
    }

    // MARK: - 预览

    private var previewArea: some View {
        ZStack {
            Color.black
            if let image = editor.preview {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 滑条

    private var sliderRow: some View {
        HStack(spacing: 12) {
            Text(valueLabel)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 46, alignment: .trailing)
                .monospacedDigit()

            Slider(value: binding, in: -100...100)
                .tint(.yellow)
                .onChange(of: binding.wrappedValue) { _, _ in
                    editor.refreshPreview()
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var intensityRow: some View {
        HStack(spacing: 12) {
            Text("\(Int((editor.lutIntensity * 100).rounded()))%")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 46, alignment: .trailing)
                .monospacedDigit()

            Slider(value: $editor.lutIntensity, in: 0...1)
                .tint(.yellow)
                .onChange(of: editor.lutIntensity) { _, _ in
                    editor.refreshPreview()
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: - LUT 条

    private var lutStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                lutChip(title: "无", selected: editor.lut == nil) {
                    editor.lut = nil
                    editor.refreshPreview()
                }

                ForEach(lutInfos.filter { $0.ok }) { info in
                    lutChip(title: info.name, selected: editor.lut?.id == info.id) {
                        editor.lut = LUTStore.shared.load(fileName: info.id)
                        editor.refreshPreview()
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
    }

    private func lutChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(selected ? Color.black : Color.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background {
                    Capsule().fill(selected ? Color.yellow : Color.white.opacity(0.14))
                }
        }
        .buttonStyle(.pressable)
    }

    // MARK: - 工具行

    private var toolRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Tool.allCases) { item in
                    let active = tool == item

                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            tool = item
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 14, weight: .medium))
                            Text(item.label)
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                        }
                        .foregroundStyle(active ? Color.black : Color.white.opacity(0.8))
                        .frame(width: 52, height: 46)
                        .background {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(active ? Color.yellow : Color.white.opacity(0.1))
                        }
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
    }

    // MARK: - 绑定

    private var binding: Binding<Double> {
        switch tool {
        case .exposure: return $editor.exposure
        case .contrast: return $editor.contrast
        case .saturation: return $editor.saturation
        case .temperature: return $editor.temperature
        case .sharpness: return $editor.sharpness
        case .vignette: return $editor.vignette
        case .lut: return $editor.lutIntensity
        }
    }

    private var valueLabel: String {
        let value: Double
        switch tool {
        case .exposure: value = editor.exposure
        case .contrast: value = editor.contrast
        case .saturation: value = editor.saturation
        case .temperature: value = editor.temperature
        case .sharpness: value = editor.sharpness
        case .vignette: value = editor.vignette
        case .lut: value = editor.lutIntensity * 100
        }
        return String(format: "%+.0f", value)
    }

    // MARK: - 逻辑

    private func loadLUTs() {
        let files = LUTStore.shared.listFiles()
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
                }
            }
            DispatchQueue.main.async { lutInfos = infos }
        }
    }

    private func save() {
        saving = true
        guard let data = editor.renderFull() else {
            saving = false
            return
        }

        PhotoSaver.save(photoData: data, movieURL: nil) { _ in }
        _ = CaptureStore.shared.save(photoData: data, movieURL: nil)

        onSaved()
        saving = false
        dismiss()
    }
}
