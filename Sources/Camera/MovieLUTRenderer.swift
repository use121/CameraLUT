import AVFoundation
import CoreImage
import CoreVideo

/// 把实况照片的那段视频逐帧套上 LUT，输出一个新文件。
/// 失败时返回 nil，调用方回退到原始视频。
enum MovieLUTRenderer {

    static func render(input: URL, output: URL, lut: LUT3D, intensity: Double, completion: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = process(input: input, output: output, lut: lut, intensity: intensity)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func process(input: URL, output: URL, lut: LUT3D, intensity: Double) -> URL? {
        let asset = AVURLAsset(url: input)

        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let size = track.naturalSize
        guard size.width > 0, size.height > 0 else { return nil }

        guard let reader = try? AVAssetReader(asset: asset) else { return nil }

        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { return nil }
        reader.add(readerOutput)

        try? FileManager.default.removeItem(at: output)
        guard let writer = try? AVAssetWriter(outputURL: output, fileType: .mov) else { return nil }

        let writerSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false

        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: bufferAttrs
        )

        guard writer.canAdd(writerInput) else { return nil }
        writer.add(writerInput)

        guard reader.startReading(), writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext(options: [
            .workingColorSpace: LUT3D.sRGB,
            .outputColorSpace: LUT3D.sRGB,
            .cacheIntermediates: false
        ])
        let filter = lut.makeFilter(intensity: intensity)
        let colorSpace = LUT3D.sRGB

        let group = DispatchGroup()
        group.enter()

        writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "cam.lut.movie")) {
            while writerInput.isReadyForMoreMediaData {
                guard let sample = readerOutput.copyNextSampleBuffer() else {
                    writerInput.markAsFinished()
                    group.leave()
                    return
                }

                guard let source = CMSampleBufferGetImageBuffer(sample) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)

                var image = CIImage(cvPixelBuffer: source)
                if let filter {
                    filter.setValue(image, forKey: kCIInputImageKey)
                    if let out = filter.outputImage {
                        image = out
                    }
                }

                guard let pool = adaptor.pixelBufferPool else { continue }
                var destination: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess,
                      let destination else { continue }

                ciContext.render(image, to: destination, bounds: image.extent, colorSpace: colorSpace)
                adaptor.append(destination, withPresentationTime: pts)
            }
        }

        group.wait()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()

        if writer.status == .completed {
            return output
        }
        return nil
    }
}
