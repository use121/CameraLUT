import SwiftUI
import MetalKit
import CoreImage

/// 把 CIImage 渲染到 MTKView。相机每帧把画面推给 submit()，这里负责等比填充显示。
final class PreviewRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let context: CIContext?

    private var frame: CIImage?
    private let lock = NSLock()
    private weak var view: MTKView?

    override init() {
        let d = MTLCreateSystemDefaultDevice()
        device = d
        if let d = d {
            commandQueue = d.makeCommandQueue()
            context = CIContext(mtlDevice: d, options: [
                .workingColorSpace: LUT3D.sRGB,
                .outputColorSpace: LUT3D.sRGB,
                .cacheIntermediates: false
            ])
        } else {
            commandQueue = nil
            context = nil
        }
        super.init()
    }

    func attach(_ mtkView: MTKView) {
        guard let device = device else { return }
        view = mtkView
        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = false
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        mtkView.autoResizeDrawable = true
        mtkView.delegate = self
    }

    /// 线程安全地提交一帧，并请求重绘。
    func submit(_ image: CIImage) {
        lock.lock()
        frame = image
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.view?.setNeedsDisplay()
        }
    }

    func clear() {
        lock.lock()
        frame = nil
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.view?.setNeedsDisplay()
        }
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let buffer = commandQueue?.makeCommandBuffer() else { return }

        lock.lock()
        let image = frame
        lock.unlock()

        let target = CGRect(origin: .zero, size: view.drawableSize)

        guard let image, target.width > 1, target.height > 1, let context else {
            buffer.present(drawable)
            buffer.commit()
            return
        }

        let scale = max(target.width / image.extent.width, target.height / image.extent.height)
        var out = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let dx = (out.extent.width - target.width) / 2
        let dy = (out.extent.height - target.height) / 2
        out = out.cropped(to: CGRect(
            x: out.extent.origin.x + dx,
            y: out.extent.origin.y + dy,
            width: target.width,
            height: target.height
        ))
        out = out.transformed(by: CGAffineTransform(
            translationX: -out.extent.origin.x,
            y: -out.extent.origin.y
        ))

        context.render(
            out,
            to: drawable.texture,
            commandBuffer: buffer,
            bounds: target,
            colorSpace: LUT3D.sRGB
        )

        buffer.present(drawable)
        buffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

struct MetalPreview: UIViewRepresentable {
    let renderer: PreviewRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        view.backgroundColor = .black
        view.isOpaque = true
        renderer.attach(view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
