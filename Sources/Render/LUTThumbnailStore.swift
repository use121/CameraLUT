import Foundation
import CoreImage
import UIKit

/// 把每个 LUT 渲染成小缩略图，用于底部横向滤镜条。
/// 用相机当前帧做底图，所以看到的就是真实效果。
final class LUTThumbnailStore {
    static let shared = LUTThumbnailStore()

    private let context = CIContext(options: [
        .workingColorSpace: LUT3D.sRGB,
        .outputColorSpace: LUT3D.sRGB,
        .cacheIntermediates: false
    ])

    private var cache: [String: UIImage] = [:]
    private let lock = NSLock()

    /// 生成（或取缓存）缩略图。key 用文件名，空字符串代表「无 LUT」。
    func thumbnail(key: String, lut: LUT3D?, base: CIImage?, size: CGFloat = 132) -> UIImage? {
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let source = preparedBase(base, size: size) else { return nil }

        var output = source
        if let lut, let filter = lut.makeFilter(intensity: 1.0) {
            filter.setValue(source, forKey: kCIInputImageKey)
            if let filtered = filter.outputImage {
                output = filtered
            }
        }

        guard let cgImage = context.createCGImage(
            output,
            from: output.extent,
            format: .RGBA8,
            colorSpace: LUT3D.sRGB
        ) else { return nil }

        let image = UIImage(cgImage: cgImage)

        lock.lock()
        cache[key] = image
        lock.unlock()

        return image
    }

    func clear() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    // MARK: - 底图

    private func preparedBase(_ base: CIImage?, size: CGFloat) -> CIImage? {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)

        guard let base else {
            return gradientBase(rect: rect)
        }

        let extent = base.extent
        guard extent.width > 1, extent.height > 1 else {
            return gradientBase(rect: rect)
        }

        // 居中裁成正方形再缩放到目标尺寸
        let side = min(extent.width, extent.height)
        let crop = CGRect(
            x: extent.origin.x + (extent.width - side) / 2,
            y: extent.origin.y + (extent.height - side) / 2,
            width: side,
            height: side
        )
        let cropped = base.cropped(to: crop)
        let scale = size / side

        return cropped
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: -cropped.extent.origin.x * scale,
                y: -cropped.extent.origin.y * scale
            ))
    }

    /// 相机还没出帧时的占位底图
    private func gradientBase(rect: CGRect) -> CIImage? {
        let filter = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: rect.height),
            "inputPoint1": CIVector(x: rect.width, y: 0),
            "inputColor0": CIColor(red: 0.22, green: 0.30, blue: 0.52),
            "inputColor1": CIColor(red: 0.88, green: 0.66, blue: 0.45)
        ])
        return filter?.outputImage?.cropped(to: rect)
    }
}
