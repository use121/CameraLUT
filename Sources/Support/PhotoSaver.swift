import Photos
import UIKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum PhotoSaver {

    /// 给照片套 LUT。
    ///
    /// 关键点：
    /// 1. 保留原始像素尺寸，不把旋转烘焙进像素（实况照片靠方向标记对齐视频）；
    /// 2. CIContext 用 sRGB，和预览管线一致，否则成片比预览更浓；
    /// 3. **保留原始元数据**（EXIF / MakerApple 等）。实况照片的静态图带内容标识，
    ///    丢了这些 Photos 会判 PHPhotosErrorDomain 3302「资源无效」；
    /// 4. 编码容器跟原图保持一致（原图 JPEG 就出 JPEG），避免格式体系不匹配。
    static func applyLUT(to data: Data, lut: LUT3D?, intensity: Double, preserveFormat: Bool) -> Data {
        guard let lut, let filter = lut.makeFilter(intensity: intensity) else { return data }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return data }

        let sourceProperties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let orientationRaw = (sourceProperties[kCGImagePropertyOrientation] as? UInt32) ?? 1

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

        // 保留原始元数据，只覆盖压缩质量和方向
        var properties = sourceProperties
        properties[kCGImageDestinationLossyCompressionQuality] = 0.92
        properties[kCGImagePropertyOrientation] = orientationRaw
        properties.removeValue(forKey: kCGImagePropertyPixelWidth)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight)

        let sourceType = (CGImageSourceGetType(source) as String?) ?? UTType.jpeg.identifier

        if preserveFormat {
            // 实况照片：容器跟原图一致，最大兼容
            return encode(cgImage, type: sourceType, properties: properties) ?? data
        }

        // 普通照片：优先 HEIC 省空间
        if let heic = encode(cgImage, type: UTType.heic.identifier, properties: properties) {
            return heic
        }
        return encode(cgImage, type: sourceType, properties: properties) ?? data
    }

    // MARK: - 编码

    private static func encode(_ cgImage: CGImage, type: String, properties: [CFString: Any]) -> Data? {
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

    enum SaveResult {
        case livePhoto
        case plainPhoto
        case failed(Error?)
    }

    /// 保存为普通照片，或（视频有效时）保存为实况照片。
    /// allowPlainFallback = false 时不自动降级成普通照片，交给调用方决定重试策略。
    static func save(
        photoData: Data,
        movieURL: URL?,
        allowPlainFallback: Bool = true,
        completion: @escaping (SaveResult) -> Void
    ) {
        let validMovie = validatedMovie(movieURL)

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(.failed(nil)) }
                return
            }

            performSave(photoData: photoData, movieURL: validMovie) { success, error in
                if success {
                    DispatchQueue.main.async {
                        completion(validMovie != nil ? .livePhoto : .plainPhoto)
                    }
                    return
                }

                // 实况配对失败 → 退一步，只存普通照片
                if validMovie != nil, allowPlainFallback {
                    performSave(photoData: photoData, movieURL: nil) { fallbackOK, fallbackError in
                        DispatchQueue.main.async {
                            completion(fallbackOK ? .plainPhoto : .failed(fallbackError ?? error))
                        }
                    }
                } else {
                    DispatchQueue.main.async { completion(.failed(error)) }
                }
            }
        }
    }

    private static func performSave(
        photoData: Data,
        movieURL: URL?,
        completion: @escaping (Bool, Error?) -> Void
    ) {
        let uti = detectUTI(photoData)

        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()

            let photoOptions = PHAssetResourceCreationOptions()
            photoOptions.uniformTypeIdentifier = uti
            request.addResource(with: .photo, data: photoData, options: photoOptions)

            if let movieURL {
                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.uniformTypeIdentifier = UTType.quickTimeMovie.identifier
                videoOptions.shouldMoveFile = false
                request.addResource(with: .pairedVideo, fileURL: movieURL, options: videoOptions)
            }
        } completionHandler: { success, error in
            completion(success, error)
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

    /// 按文件头判断真实格式
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
