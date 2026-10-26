import Photos
import UIKit
import CoreImage

enum PhotoSaver {

    /// 把 LUT 应用到照片数据上，返回 JPEG。没有 LUT 就原样返回。
    static func applyLUT(to data: Data, lut: LUT3D?) -> Data {
        guard let lut, let filter = lut.makeFilter() else { return data }
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return data }

        filter.setValue(source, forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return data }

        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return data }

        let image = UIImage(cgImage: cgImage)
        return image.jpegData(compressionQuality: 0.95) ?? data
    }

    /// 保存为普通照片，或（同时提供视频时）保存为实况照片。
    static func save(
        photoData: Data,
        movieURL: URL?,
        completion: @escaping (Bool, Error?) -> Void
    ) {
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

                if let movieURL {
                    let videoOptions = PHAssetResourceCreationOptions()
                    videoOptions.shouldMoveFile = false
                    request.addResource(with: .pairedVideo, fileURL: movieURL, options: videoOptions)
                }
            } completionHandler: { success, error in
                DispatchQueue.main.async { completion(success, error) }
            }
        }
    }

    private static func detectUTI(_ data: Data) -> String {
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 {
            return "public.jpeg"
        }
        return "public.heic"
    }
}
