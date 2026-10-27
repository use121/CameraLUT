import SwiftUI
import AVKit
import UIKit

struct GalleryView: View {
    @ObservedObject var model: CameraModel
    @Environment(\.dismiss) private var dismiss

    @State private var selecting = false
    @State private var selectedIDs = Set<String>()
    @State private var detailIndex: Int?
    @State private var showDetail = false

    private let columns = [
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3)
    ]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(selecting ? "已选 \(selectedIDs.count) 张" : "图库")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        .fullScreenCover(isPresented: $showDetail) {
            if let start = detailIndex {
                CapturePager(
                    items: model.captures,
                    startIndex: start,
                    onDelete: { item in delete([item]) },
                    onChanged: {
                        model.captures = CaptureStore.shared.items()
                        model.lastCapture = model.captures.first
                        showDetail = false
                    }
                )
            }
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if model.captures.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("还没有拍过照片")
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(Array(model.captures.enumerated()), id: \.element.id) { index, item in
                        cell(item, index: index)
                    }
                }
                .padding(3)
            }
        }
    }

    private func cell(_ item: CaptureItem, index: Int) -> some View {
        let isSelected = selectedIDs.contains(item.id)

        return Button {
            if selecting {
                toggleSelection(item)
            } else {
                detailIndex = index
                showDetail = true
            }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                if let image = CaptureStore.shared.thumbnail(for: item) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }

                if item.videoURL != nil {
                    Image(systemName: "livephoto")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(5)
                }

                if selecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.yellow : Color.white)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(height: 118)
            .clipped()
            .overlay {
                if isSelected {
                    Rectangle().strokeBorder(.yellow, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if selecting {
                Button("全选") {
                    selectedIDs = Set(model.captures.map { $0.id })
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            if selecting {
                HStack(spacing: 12) {
                    Button("取消") {
                        selecting = false
                        selectedIDs.removeAll()
                    }

                    Button(role: .destructive) {
                        deleteSelected()
                    } label: {
                        Text("删除")
                            .fontWeight(.semibold)
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            } else {
                HStack(spacing: 12) {
                    if !model.captures.isEmpty {
                        Button("选择") { selecting = true }
                    }
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: - 逻辑

    private func toggleSelection(_ item: CaptureItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    private func deleteSelected() {
        let targets = model.captures.filter { selectedIDs.contains($0.id) }
        delete(targets)
        selecting = false
        selectedIDs.removeAll()
    }

    private func delete(_ items: [CaptureItem]) {
        for item in items {
            CaptureStore.shared.delete(item)
        }
        model.captures = CaptureStore.shared.items()
        model.lastCapture = model.captures.first
    }
}

/// 全屏浏览，支持左右滑动切换
struct CapturePager: View {
    let items: [CaptureItem]
    let startIndex: Int
    let onDelete: (CaptureItem) -> Void
    var onChanged: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var showVideo = false
    @State private var editingItem: CaptureItem?

    init(
        items: [CaptureItem],
        startIndex: Int,
        onDelete: @escaping (CaptureItem) -> Void,
        onChanged: @escaping () -> Void = {}
    ) {
        self.items = items
        self.startIndex = startIndex
        self.onDelete = onDelete
        self.onChanged = onChanged
        _index = State(initialValue: min(max(startIndex, 0), max(items.count - 1, 0)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                    page(item)
                        .tag(position)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)

                    Spacer()

                    if items.count > 1 {
                        Text("\(index + 1) / \(items.count)")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .glassEffect(.regular, in: .capsule)
                    }

                    Spacer()

                    if let current = currentItem, current.videoURL != nil {
                        Button {
                            showVideo = true
                        } label: {
                            Image(systemName: "livephoto.play")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                    }

                    if let current = currentItem {
                        Button {
                            editingItem = current
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                    }
                }
                .padding(.horizontal, 16)

                Spacer()

                if let current = currentItem {
                    Text(current.date.formatted(.dateTime.year().month().day().hour().minute()))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.bottom, 30)
                }
            }
        }
        .sheet(isPresented: $showVideo) {
            if let url = currentItem?.videoURL {
                VideoPlayer(player: AVPlayer(url: url))
                    .ignoresSafeArea()
            }
        }
        .sheet(item: $editingItem) { target in
            EditorView(item: target, onSaved: onChanged)
        }
    }

    private var currentItem: CaptureItem? {
        guard index >= 0, index < items.count else { return nil }
        return items[index]
    }

    @ViewBuilder
    private func page(_ item: CaptureItem) -> some View {
        if let image = UIImage(contentsOfFile: item.imageURL.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Color.black
        }
    }
}
