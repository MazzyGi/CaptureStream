#if canImport(Metal) && canImport(CoreVideo)
import CoreVideo
import Foundation
import Metal
import CaptureStreamCore

/// 渲染循环：专用线程从有界队列取帧 → MetalRenderer 绘制。
/// 支持 vsync 驱动（CVDisplayLink）或立即模式（§22 FramePacing）。
public final class RenderLoop {

    private var thread: Thread?
    private let condition = NSCondition()
    private var running = false
    private var stopped = false

    public let renderer: MetalRenderer?
    public var capture: VideoCaptureSession?
    public var testQueue: BoundedFrameQueue<CapturedFrame>?
    public private(set) var settingsMirror = SettingsMirror(scaling: .fit, filter: .bilinear,
                                                            aspect: .original, customScale: 1.0,
                                                            sharpen: 0, vsync: true,
                                                            interpolation: false, superResolution: false)
    private let mirrorLock = NSLock()
    public var monitor: PerformanceMonitor?

    // 插帧状态：上一帧纹理（线性混合实现）
    private var previousFrame: CapturedFrame?
    public var interpolationEnabled: Bool { settingsMirror.interpolation }
    public private(set) var interpolatedCount: UInt64 = 0

    public weak var layer: CAMetalLayer?

    public private(set) var viewportSize: Size = Size(width: 1920, height: 1080)

    public init(renderer: MetalRenderer?) {
        self.renderer = renderer
    }

    /// 主线程调用：同步当前设置（渲染线程只读镜像）。
    public func updateSettings(_ mirror: SettingsMirror) {
        mirrorLock.lock()
        settingsMirror = mirror
        mirrorLock.unlock()
    }

    public func start() {
        guard !running else { return }
        running = true
        stopped = false
        let t = Thread { [weak self] in self?.run() }
        t.name = "capture.render"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    public func stop() {
        condition.lock()
        running = false
        condition.signal()
        condition.unlock()
        // 等待渲染线程真正退出（Thread 无 join）：
        // restart 时旧线程与新线程并发 nextDrawable 会交替 present → "果冻闪屏"
        let deadline = Date().addingTimeInterval(2.0)
        while !stopped && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        thread = nil
    }

    public func updateViewport(_ size: Size) {
        condition.lock()
        viewportSize = size
        condition.unlock()
    }

    private func run() {
        var idleCount = 0
        while true {
            condition.lock()
            let isRunning = running
            condition.unlock()
            if !isRunning { break }

            // 取帧（100ms 超时避免忙等；设备/测试图案共用渲染队列语义由外部装配）
            let source: BoundedFrameQueue<CapturedFrame>? = capture != nil ? nil : testQueue
            let frame = capture?.nextFrame(timeout: 0.1) ?? source?.pop(timeout: 0.1)
            guard let frame else {
                idleCount += 1
                if idleCount % 50 == 0 { renderer?.purgeCache() }
                continue
            }
            idleCount = 0

            guard let renderer, let layer else { continue }
            mirrorLock.lock()
            let s = settingsMirror
            mirrorLock.unlock()
            let inputSize = Size(width: CVPixelBufferGetWidth(frame.pixelBuffer),
                                 height: CVPixelBufferGetHeight(frame.pixelBuffer))
            // Pixel Perfect：按 drawableSize 像素（已含 backing scale）
            let vp = viewportPixels()
            let dest = ScalingMath.destinationRect(input: inputSize, viewport: vp,
                                                   mode: s.scaling, aspect: s.aspect,
                                                   customScale: s.customScale)
            let filter = ScalingMath.filter(for: s.scaling, requested: s.filter)
            var tr = frame.trace
            monitor?.recordProcess(&tr, at: CFAbsoluteTimeGetCurrent())

            // 插帧（实验性，§12）：真实帧之间渲染一个"中间帧"。
            // 第一阶段线性混合——在 VSync 空档渲染 prev/cur 混合近似中间帧，
            // 渲染 FPS 可达 2x 输入；不是运动补偿（在 UI 明示 Experimental）。
            if s.interpolation, let prev = previousFrame,
               CVPixelBufferGetWidth(prev.pixelBuffer) == CVPixelBufferGetWidth(frame.pixelBuffer),
               CVPixelBufferGetHeight(prev.pixelBuffer) == CVPixelBufferGetHeight(frame.pixelBuffer) {
                renderer.renderBlended(a: prev.pixelBuffer, b: frame.pixelBuffer, t: 0.5,
                                       trace: tr, layer: layer,
                                       drawableSize: CGSize(width: vp.width, height: vp.height),
                                       destRect: dest, filter: filter, sharpen: s.sharpen,
                                       vsyncEnabled: s.vsync)
                interpolatedCount += 1
            }
            previousFrame = frame

            renderer.render(pixelBuffer: frame.pixelBuffer, trace: tr,
                            layer: layer, drawableSize: CGSize(width: vp.width, height: vp.height),
                            destRect: dest, filter: filter, sharpen: s.sharpen,
                            vsyncEnabled: s.vsync)
        }
        stopped = true
    }

    private func viewportPixels() -> Size {
        if let layer {
            // drawableSize 已是物理像素（CAMetalLayer 语义），Pixel Perfect 依赖它
            return Size(width: Int(max(layer.drawableSize.width, 1)),
                        height: Int(max(layer.drawableSize.height, 1)))
        }
        return viewportSize
    }
}

import AppKit
#endif
