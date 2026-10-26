import Foundation
import UIKit

struct CaptureItem: Identifiable, Equatable {
    let id: String
    let imageURL: URL
    let videoURL: URL?
    let date: Date
}

/// 在 App 沙盒里存一份拍过的照片，供应用内预览。
/// 相册那份是给系统用的，这份是给 App 自己看的。
final class CaptureStore {
    static let shared = CaptureStore()

    private let folder: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = docs.appendingPathComponent("Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @discardableResult
    func save(photoData: Data, movieURL: URL?) -> CaptureItem? {
        let id = UUID().uuidString
        let imageURL = folder.appendingPathComponent("\(id).jpg")

        do {
            try photoData.write(to: imageURL)
        } catch {
            return nil
        }

        var savedVideo: URL?
        if let movieURL {
            let videoURL = folder.appendingPathComponent("\(id).mov")
            if (try? FileManager.default.copyItem(at: movieURL, to: videoURL)) != nil {
                savedVideo = videoURL
            }
        }

        return CaptureItem(id: id, imageURL: imageURL, videoURL: savedVideo, date: Date())
    }

    func items() -> [CaptureItem] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.creationDateKey]
        )) ?? []

        return files
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .compactMap { url -> CaptureItem? in
                let id = url.deletingPathExtension().lastPathComponent
                let videoURL = folder.appendingPathComponent("\(id).mov")
                let hasVideo = FileManager.default.fileExists(atPath: videoURL.path)
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                return CaptureItem(id: id, imageURL: url, videoURL: hasVideo ? videoURL : nil, date: date)
            }
            .sorted { $0.date > $1.date }
    }

    func latest() -> CaptureItem? {
        items().first
    }

    func delete(_ item: CaptureItem) {
        try? FileManager.default.removeItem(at: item.imageURL)
        if let videoURL = item.videoURL {
            try? FileManager.default.removeItem(at: videoURL)
        }
    }

    func thumbnail(for item: CaptureItem, maxSize: CGFloat = 300) -> UIImage? {
        guard let data = try? Data(contentsOf: item.imageURL),
              let image = UIImage(data: data) else { return nil }

        let scale = min(maxSize / max(image.size.width, 1), maxSize / max(image.size.height, 1), 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
