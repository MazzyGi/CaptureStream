#if canImport(CoreVideo) && canImport(CoreMedia)
import CoreVideo
import CoreMedia
import Foundation
import CaptureStreamCore

/// 测试图案源：生成 SMPTE 风格彩条 + 帧计数，替代真实采集卡驱动整条管线。
/// 用于 CI（无设备）与本地开发验证 capture → queue → render 全链路（§46）。
public final class TestPatternSource {

    public struct Config {
        public var width: Int
        public var height: Int
        public var fps: Double
        public var pixelFormat: OSType
        public init(width: Int = 1920, height: Int = 1080, fps: Double = 60,
                    pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
            self.width = width; self.height = height; self.fps = fps; self.pixelFormat = pixelFormat
        }
    }

    private let config: Config
    private let queue: BoundedFrameQueue<CapturedFrame>
    private var thread: Thread?
    private var stopFlag = false
    private let lock = NSLock()
    private var frameCounter: UInt64 = 0
    public var monitor: PerformanceMonitor?

    /// 模拟掉帧：每 N 帧跳过一次输出（测试掉帧检测）。
    public var simulateDropEveryNFrames: Int = 0

    public init(config: Config = Config(), queue: BoundedFrameQueue<CapturedFrame>) {
        self.config = config
        self.queue = queue
    }

    public func start() {
        guard thread == nil else { return }
        stopFlag = false
        let t = Thread { [weak self] in self?.generate() }
        t.name = "capture.testpattern"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    public func stop() {
        lock.lock(); stopFlag = true; lock.unlock()
        thread = nil
        queue.clear()
    }

    private func generate() {
        let interval = 1.0 / config.fps
        var pool: CVPixelBufferPool?
        var last = Date()
        while true {
            lock.lock(); let stopped = stopFlag; lock.unlock()
            if stopped { break }

            // 相位对齐的固定节奏
            let sleepUntil = last.addingTimeInterval(interval)
            let nap = sleepUntil.timeIntervalSinceNow
            if nap > 0 { Thread.sleep(forTimeInterval: nap) }
            last = sleepUntil

            lock.lock()
            if simulateDropEveryNFrames > 0, frameCounter > 0,
               Int(frameCounter) % simulateDropEveryNFrames == 0 {
                frameCounter += 1      // ID 跳变：模拟传输丢帧（§44）
                lock.unlock()
                continue
            }
            lock.unlock()

            guard let pb = makeFrame() else { continue }
            let now = CFAbsoluteTimeGetCurrent()
            lock.lock()
            frameCounter += 1
            let id = frameCounter
            lock.unlock()
            var trace = monitor?.recordCapture(frameID: id, at: now, pts: Int64(now * 1_000_000)) ??
                        FrameTrace(frameID: id, pts: Int64(now * 1_000_000))
            trace.capturedAt = now
            monitor?.recordDecode(&trace, at: now)
            queue.push(CapturedFrame(pixelBuffer: pb, trace: trace))
        }
    }

    private func makeFrame() -> CVPixelBuffer? {
        let w = config.width, h = config.height
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, config.pixelFormat, nil, &pb)
        guard let buffer = pb else { return nil }

        if config.pixelFormat == kCVPixelFormatType_32BGRA {
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let colors: [(UInt8, UInt8, UInt8)] = [(192, 192, 192), (192, 192, 0), (0, 192, 192),
                                                   (0, 192, 0), (192, 0, 192), (192, 0, 0), (0, 0, 192)]
            let bar = w / colors.count
            let dst = base.assumingMemoryBound(to: UInt8.self)
            // 帧计数条纹（验证帧在流动）
            lock.lock(); let f = frameCounter; lock.unlock()
            let band = Int(f % 8) * h / 8
            for y in 0..<h {
                for x in 0..<w {
                    let c = colors[min(x / bar, colors.count - 1)]
                    let bright: Double = (y > band && y < band + h / 16) ? 0.5 : 1.0
                    let o = y * stride + x * 4
                    dst[o] = UInt8(Double(c.0) * bright)
                    dst[o + 1] = UInt8(Double(c.1) * bright)
                    dst[o + 2] = UInt8(Double(c.2) * bright)
                    dst[o + 3] = 255
                }
            }
            return buffer
        }

        // NV12 双平面
        if config.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           config.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                  let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
            let uvPtr = uvBase.assumingMemoryBound(to: UInt8.self)
            lock.lock(); let f = frameCounter; lock.unlock()
            let band = Int(f % 8) * h / 8
            for y in 0..<h {
                for x in 0..<w {
                    let bar = w / 7
                    let idx = min(x / bar, 6)
                    let lum: UInt8 = (y > band && y < band + h / 16) ? 40 : UInt8(30 + idx * 30)
                    yPtr[y * yStride + x] = lum
                }
            }
            let uvH = CVPixelBufferGetHeightOfPlane(buffer, 1)
            let uvW = CVPixelBufferGetWidthOfPlane(buffer, 1)
            for y in 0..<uvH {
                for x in 0..<uvW {
                    let o = y * uvStride + x * 2
                    uvPtr[o] = 128; uvPtr[o + 1] = 128
                    if x % 64 < 8 { uvPtr[o] = 180 }    // 色度竖纹
                }
            }
            return buffer
        }
        return buffer
    }
}
#endif
