import Photos
import UIKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum PhotoSaver {

    /// 给照片套 LUT。
    ///
    /// 三个关键点：
    /// 1. 保留原始像素尺寸和方向（不把旋转烘焙进像素），否则实况照片配对会失败；
    /// 2. CIContext 显式用 sRGB 工作空间，和预览管线一致，否则成片会比预览更浓郁；
    /// 3. 输出优先用 HEIC —— 实况视频是 HEVC，静态图用 JPEG 会导致
    ///    PHPhotosErrorDomain 3302（资源无效），而且 HEIC 体积小得多。
    static func applyLUT(to data: Data, lut: LUT3D?, intensity: Double) -> Data {
        guard let lut, let filter = lut.makeFilter(intensity: intensity) else { return data }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return data
        }

        let orientationRaw = (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1

        guard let input = CIImage(data: data) else { return data }
        filter.setValue(input, forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return data }

        let context = CIContext(options: [
            .workingColorSpace: LUT3D.sRGB,
            .outputColorSpace: LUT3D.sRGB,
            .cacheIntermediates: false
        ])

        guard let cgImage = context.createCGImage(
            output,
            from: output.extent,
            format: .RGBA8,
            colorSpace: LUT3D.sRGB
        ) else { return data }

        return encode(cgImage, orientation: orientationRaw) ?? data
    }

    // MARK: - 编码

    private static func encode(_ cgImage: CGImage, orientation: UInt32) -> Data? {
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyOrientation: orientation
        ]

        // 优先 HEIC：和实况视频的 HEVC 同族，体积也小
        if let data = encodeWith(cgImage, type: UTType.heic.identifier, properties: properties) {
            return data
        }
        // 兜底 JPEG
        return encodeWith(cgImage, type: UTType.jpeg.identifier, properties: properties)
    }

    private static func encodeWith(_ cgImage: CGImage, type: String, properties: [CFString: Any]) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            type as CFString,
            1,
            nil
        ) else { return nil }

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return output as Data
    }

    // MARK: - 保存

    /// 保存为普通照片，或（视频有效时）保存为实况照片。
    static func save(
        photoData: Data,
        movieURL: URL?,
        completion: @escaping (Bool, Error?) -> Void
    ) {
        let validMovie = validatedMovie(movieURL)

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(false, nil) }
                return
            }

            let uti = detectUTI(photoData)

            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()

                let photoOptions = PHAssetResourceCreationOptions()
                photoOptions.uniformTypeIdentifier = uti
                request.addResource(with: .photo, data: photoData, options: photoOptions)

                if let validMovie {
                    let videoOptions = PHAssetResourceCreationOptions()
                    videoOptions.uniformTypeIdentifier = UTType.quickTimeMovie.identifier
                    videoOptions.shouldMoveFile = false
                    request.addResource(with: .pairedVideo, fileURL: validMovie, options: videoOptions)
                }
            } completionHandler: { success, error in
                DispatchQueue.main.async { completion(success, error) }
            }
        }
    }

    // MARK: - 私有

    private static func validatedMovie(_ url: URL?) -> URL? {
        guard let url else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size > 1024 else { return nil }
        return url
    }

    /// 按文件头判断真实格式，别只看扩展名
    private static func detectUTI(_ data: Data) -> String {
        if data.count >= 3, data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF {
            return UTType.jpeg.identifier
        }
        if data.count >= 12 {
            let box = data.subdata(in: 4..<8)
            if box == Data("ftyp".utf8) {
                let brand = data.subdata(in: 8..<12)
                let brandString = String(data: brand, encoding: .ascii) ?? ""
                if brandString.hasPrefix("hei") || brandString.hasPrefix("mif1") || brandString.hasPrefix("msf1") {
                    return UTType.heic.identifier
                }
            }
        }
        return UTType.heic.identifier
    }
}
