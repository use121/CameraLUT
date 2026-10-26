import SwiftUI
import AVKit
import UIKit

struct GalleryView: View {
    @ObservedObject var model: CameraModel
    @Environment(\.dismiss) private var dismiss

    @State private var selected: CaptureItem?

    private let columns = [
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3)
    ]

    var body: some View {
        NavigationStack {
            Group {
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
                            ForEach(model.captures) { item in
                                Button {
                                    selected = item
                                } label: {
                                    thumbnail(item)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        CaptureStore.shared.delete(item)
                                        model.captures = CaptureStore.shared.items()
                                        model.lastCapture = model.captures.first
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(3)
                    }
                }
            }
            .navigationTitle("图库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .fullScreenCover(item: $selected) { item in
            CaptureDetailView(item: item)
        }
    }

    @ViewBuilder
    private func thumbnail(_ item: CaptureItem) -> some View {
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
        }
        .frame(height: 118)
        .clipped()
        .contentShape(Rectangle())
    }
}

struct CaptureDetailView: View {
    let item: CaptureItem
    @Environment(\.dismiss) private var dismiss

    @State private var showVideo = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = UIImage(contentsOfFile: item.imageURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    Spacer()

                    if item.videoURL != nil {
                        Button {
                            showVideo = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "livephoto.play")
                                Text("播放实况")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                Text(item.date.formatted(.dateTime.year().month().day().hour().minute()))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $showVideo) {
            if let videoURL = item.videoURL {
                VideoPlayer(player: AVPlayer(url: videoURL))
                    .ignoresSafeArea()
            }
        }
    }
}
