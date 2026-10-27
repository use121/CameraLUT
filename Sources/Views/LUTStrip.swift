import SwiftUI
import CoreImage
import UIKit

/// 底部 LUT 横向滤镜条：每个 LUT 实时渲染成缩略图，点一下直接换。
struct LUTStrip: View {
    @ObservedObject var model: CameraModel

    @State private var thumbs: [String: UIImage] = [:]

    private var token: String {
        model.lutInfos.map { $0.id }.joined(separator: "|")
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                item(key: "", title: "原图")
                ForEach(model.lutInfos.filter { $0.ok }) { info in
                    item(key: info.id, title: info.name)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .task(id: token) {
            await build()
        }
    }

    private func item(key: String, title: String) -> some View {
        let selected = (model.selectedFile ?? "") == key

        return Button {
            model.select(key.isEmpty ? nil : key)
            if !key.isEmpty, !model.lutEnabled {
                model.lutEnabled = true
            }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    if let image = thumbs[key] {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.primary.opacity(0.12))
                    }
                }
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            selected ? Color.yellow : Color.white.opacity(0.18),
                            lineWidth: selected ? 2 : 0.8
                        )
                }

                Text(title)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(selected ? Color.yellow : Color.primary.opacity(0.7))
                    .lineLimit(1)
                    .frame(width: 62)
            }
        }
        .buttonStyle(.plain)
    }

    private func build() async {
        let base = model.session.currentSnapshot()
        let list = model.lutInfos.filter { $0.ok }.map { $0.id }

        let result: [String: UIImage] = await Task.detached(priority: .userInitiated) {
            var out: [String: UIImage] = [:]
            if let none = LUTThumbnailStore.shared.thumbnail(key: "__none__", lut: nil, base: base) {
                out[""] = none
            }
            for id in list {
                guard let lut = LUTStore.shared.load(fileName: id) else { continue }
                if let thumb = LUTThumbnailStore.shared.thumbnail(key: id, lut: lut, base: base) {
                    out[id] = thumb
                }
            }
            return out
        }.value

        thumbs = result
    }
}
