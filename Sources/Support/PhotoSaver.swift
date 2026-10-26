import Photos
import UIKit
import CoreImage
import ImageIO

enum PhotoSaver {

    /// 给照片套 LUT。
    /// 关键：保留原始像素尺寸和 EXIF 方向，不把旋转烘焙进像素——
    /// 否则实况照片的静态图和视频尺寸/方向不一致，PHPhotoLibrary 配对会抛异常直接崩溃。
    static func applyLUT(to data: Data, lut: LUT3D?) -> Data {
        guard let lut, let filter = lut.makeFilter() else { return data }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return data
        }

        let orientationRaw = (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let uiOrientation = mapOrientation(orientationRaw)

        guard let input = CIImage(data: data) else { return data }
        filter.setValue(input, forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return data }

        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return data }

        let image = UIImage(cgImage: cgImage, scale: 1, orientation: uiOrientation)
        return image.jpegData(compressionQuality: 0.95) ?? data
    }

    /// 保存为普通照片，或（视频有效时）保存为实况照片。
    static func save(
        photoData: Data,
        movieURL: URL?,
        completion: @escaping (Bool, Error?) -> Void
    ) {
        // 先校验视频，避免把无效资源塞进 Live Photo 导致崩溃
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
                    videoOptions.uniformTypeIdentifier = "com.apple.quicktime-movie"
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

    private static func detectUTI(_ data: Data) -> String {
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 {
            return "public.jpeg"
        }
        return "public.heic"
    }

    private static func mapOrientation(_ raw: UInt32) -> UIImage.Orientation {
        switch raw {
        case 2: return .upMirrored
        case 3: return .down
        case 4: return .downMirrored
        case 5: return .leftMirrored
        case 6: return .right
        case 7: return .rightMirrored
        case 8: return .left
        default: return .up
        }
    }
}
