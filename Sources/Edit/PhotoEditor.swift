import Foundation
import CoreImage
import UIKit

/// 照片编辑管线。所有参数为 0 时输出等于原图。
final class PhotoEditor: ObservableObject {
    let original: CIImage
    let extent: CGRect

    // 基础调整，范围 -100...100（0 = 不变）
    @Published var exposure: Double = 0
    @Published var contrast: Double = 0
    @Published var saturation: Double = 0
    @Published var temperature: Double = 0
    @Published var sharpness: Double = 0
    @Published var vignette: Double = 0

    // LUT
    @Published var lut: LUT3D?
    @Published var lutIntensity: Double = 1.0

    @Published var preview: UIImage?

    private let context = CIContext(options: [
        .workingColorSpace: LUT3D.sRGB,
        .outputColorSpace: LUT3D.sRGB,
        .cacheIntermediates: false
    ])

    private var renderToken = 0
    private let queue = DispatchQueue(label: "photo.editor", qos: .userInitiated)

    init(image: CIImage) {
        self.original = image
        self.extent = image.extent
    }

    var hasChanges: Bool {
        abs(exposure) > 0.01
            || abs(contrast) > 0.01
            || abs(saturation) > 0.01
            || abs(temperature) > 0.01
            || abs(sharpness) > 0.01
            || abs(vignette) > 0.01
            || (lut != nil && lutIntensity > 0.01)
    }

    func reset() {
        exposure = 0
        contrast = 0
        saturation = 0
        temperature = 0
        sharpness = 0
        vignette = 0
        lutIntensity = 1.0
    }

    // MARK: - 管线

    /// scale 用于让模糊半径在预览尺寸下和全尺寸保持一致
    private func apply(_ input: CIImage, scale: CGFloat) -> CIImage {
        var image = input

        if abs(exposure) > 0.01 {
            let f = CIFilter(name: "CIExposureAdjust")
            f?.setValue(image, forKey: kCIInputImageKey)
            f?.setValue(exposure / 100.0 * 2.0, forKey: kCIInputEVKey)
            image = f?.outputImage ?? image
        }

        if abs(temperature) > 0.01 {
            let f = CIFilter(name: "CITemperatureAndTint")
            f?.setValue(image, forKey: kCIInputImageKey)
            f?.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            f?.setValue(CIVector(x: 6500 + temperature * 22, y: 0), forKey: "inputTargetNeutral")
            image = f?.outputImage ?? image
        }

        if abs(contrast) > 0.01 || abs(saturation) > 0.01 {
            let f = CIFilter(name: "CIColorControls")
            f?.setValue(image, forKey: kCIInputImageKey)
            f?.setValue(1.0 + contrast / 100.0, forKey: kCIInputContrastKey)
            f?.setValue(1.0 + saturation / 100.0, forKey: kCIInputSaturationKey)
            image = f?.outputImage ?? image
        }

        if abs(sharpness) > 0.01 {
            if sharpness > 0 {
                let f = CIFilter(name: "CISharpenLuminance")
                f?.setValue(image, forKey: kCIInputImageKey)
                f?.setValue(sharpness / 100.0 * 1.2, forKey: kCIInputSharpnessKey)
                image = f?.outputImage ?? image
            } else {
                // 负值 = 去锐化（轻微柔化）
                let f = CIFilter(name: "CIGaussianBlur")
                f?.setValue(image, forKey: kCIInputImageKey)
                f?.setValue(-sharpness / 100.0 * 1.6 * scale, forKey: kCIInputRadiusKey)
                image = (f?.outputImage ?? image).cropped(to: image.extent)
            }
        }

        if abs(vignette) > 0.01 {
            let f = CIFilter(name: "CIVignette")
            f?.setValue(image, forKey: kCIInputImageKey)
            f?.setValue(vignette / 100.0 * 1.4, forKey: kCIInputIntensityKey)
            f?.setValue(1.2, forKey: kCIInputRadiusKey)
            image = f?.outputImage ?? image
        }

        if let lut, lutIntensity > 0.01, let f = lut.makeFilter(intensity: lutIntensity) {
            f.setValue(image, forKey: kCIInputImageKey)
            image = f.outputImage ?? image
        }

        return image
    }

    // MARK: - 预览

    func refreshPreview(maxSize: CGFloat = 1400) {
        renderToken += 1
        let token = renderToken
        let source = original
        let longest = max(source.extent.width, source.extent.height)
        let scale = longest > maxSize ? maxSize / longest : 1

        queue.async { [weak self] in
            guard let self else { return }

            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let output = self.apply(scaled, scale: scale)

            guard token == self.renderToken else { return }
            guard let cgImage = self.context.createCGImage(
                output,
                from: output.extent,
                format: .RGBA8,
                colorSpace: LUT3D.sRGB
            ) else { return }

            let image = UIImage(cgImage: cgImage)
            DispatchQueue.main.async {
                if token == self.renderToken {
                    self.preview = image
                }
            }
        }
    }

    // MARK: - 导出

    func renderFull() -> Data? {
        let output = apply(original, scale: 1)
        guard let cgImage = context.createCGImage(
            output,
            from: extent,
            format: .RGBA8,
            colorSpace: LUT3D.sRGB
        ) else { return nil }

        return PhotoSaver.encodeHEIC(cgImage, quality: 0.92)
    }
}
