#if canImport(AVFoundation) && canImport(CoreVideo) && canImport(CoreMedia)
import AVFoundation
import CoreFoundation
import CoreMedia
import CoreVideo
import Foundation
import CaptureStreamCore

/// 采集输出的帧包装：CVPixelBuffer + 元数据。
public struct CapturedFrame {
    public let pixelBuffer: CVPixelBuffer
    public let trace: FrameTrace
    public init(pixelBuffer: CVPixelBuffer, trace: FrameTrace) {
        self.pixelBuffer = pixelBuffer
        self.trace = trace
    }
}

public enum CaptureSessionError: Error, CustomStringConvertible {
    case noPermission
    case deviceNotFound(String)
    case cannotConfigure(String)
    case cannotStart(String)
    case disconnected(String)

    public var description: String {
        switch self {
        case .noPermission: return "Camera permission denied (System Settings → Privacy → Camera)"
        case .deviceNotFound(let id): return "Capture device not found: \(id)"
        case .cannotConfigure(let m): return "Cannot configure capture session: \(m)"
        case .cannotStart(let m): return "Cannot start capture session: \(m)"
        case .disconnected(let m): return "Capture device disconnected: \(m)"
        }
    }
}

/// 视频采集会话：AVCaptureSession → 有界队列 → 渲染线程。
/// - 帧序列号（frameID）由本类维护：每个 output 回调 +1，
///   采集卡自身的丢帧表现为"时间戳间隔异常"，ID 连续（与设备内部序列无关）。
/// - 真正的设备序列缺失由 iOS 26 / macOS 26 AVCaptureInput 的 sequence number API 检测，
///   当前 SDK 不可用时退化为时间戳间隔检测（PerformanceMonitor 已实现）。
public final class VideoCaptureSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    public let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    /// session 所有操作（配置/启停/增删 input output）的专属串行队列——
    /// AVFoundation session 配置非线程安全，跨线程并发操作会静默失败（表现为无帧输出）。
    public let sessionQueue = DispatchQueue(label: "capture.session", qos: .userInitiated)
    private let queue = DispatchQueue(label: "capture.video", qos: .userInteractive)
    private let frameQueue: BoundedFrameQueue<CapturedFrame>

    public private(set) var currentFormat: CaptureFormatDescriptor?
    public var monitor: PerformanceMonitor?

    private var frameCounter: UInt64 = 0
    private let idLock = NSLock()
    private var configured = false

    /// 诊断：output 回调实际收到的帧数（FPS=0 时判断采集层是否供帧）。
    /// 采集线程写/主线程读——必须经 idLock。
    public var callbackFrameCount: UInt64 {
        idLock.lock(); defer { idLock.unlock() }
        return _callbackFrameCount
    }
    private var _callbackFrameCount: UInt64 = 0

    /// 诊断：设备 PTS 实测帧间隔（1/delta = 设备真实输出帧率）。
    public var measuredInputFPS: Double {
        idLock.lock(); defer { idLock.unlock() }
        return _lastPTSDeltaSec > 0 ? 1.0 / _lastPTSDeltaSec : 0
    }
    private var _lastPTSDeltaSec: Double = 0
    private var _ptsSamples: UInt64 = 0
    private var lastPTS = CMTime.invalid

    public init(frameQueueCapacity: Int = 2,
                policy: QueueOverflowPolicy = .dropOldest) {
        frameQueue = BoundedFrameQueue<CapturedFrame>(capacity: frameQueueCapacity, policy: policy)
        super.init()
        output.videoSettings = [:]   // 原生格式输出，不做 CPU 转换（§5）
        output.alwaysDiscardsLateVideoFrames = true   // 低延迟：晚帧直接丢（§22）
        output.setSampleBufferDelegate(self, queue: queue)
    }

    /// 配置并启动。format 为 nil 时选设备默认最优格式。
    /// 全程在 sessionQueue 串行执行，调用方阻塞等待完成。
    /// 注意：startRunning 必须在 commitConfiguration 之后调用，
    /// 在 begin/commit 窗口内调用会触发 AVFoundation NSException（SIGABRT）。
    public func start(deviceID: String, format: CaptureFormatDescriptor?) throws {
        var startError: Error?
        sessionQueue.sync { [self] in
            do { try configureAndStart(deviceID: deviceID, format: format) }
            catch { startError = error }
        }
        if let e = startError { throw e }
    }

    private func configureAndStart(deviceID: String, format: CaptureFormatDescriptor?) throws {
        guard permissionGranted() else { throw CaptureSessionError.noPermission }
        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            throw CaptureSessionError.deviceNotFound(deviceID)
        }
        // 顺序对齐 OBS macOS 采集（AVFVideoSource）：
        // 1. session 结构配置（仅 input/output 增删）
        // 2. commitConfiguration
        // 3. 【commit 之后】设置 device.activeFormat + 帧率（在 begin/commit 窗口内设置
        //    会在 commit 协商时被 session 重置回默认挡位——这正是"永远 25fps"的根因）
        // 4. startRunning
        var configError: CaptureSessionError?
        session.beginConfiguration()
        do {
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            guard let input = try? AVCaptureDeviceInput(device: device) else {
                throw CaptureSessionError.cannotConfigure("cannot create device input")
            }
            guard session.canAddInput(input) else {
                throw CaptureSessionError.cannotConfigure("cannot add input")
            }
            session.addInput(input)
            guard session.canAddOutput(output) else {
                throw CaptureSessionError.cannotConfigure("cannot add video output")
            }
            session.addOutput(output)
            // 注：macOS 无 .inputPriority preset（iOS only）。
            // 不设 preset，保持默认——帧率由 startRunning 后的重钉保证（见下）。
        } catch let e as CaptureSessionError {
            configError = e
        } catch {
            configError = .cannotConfigure("\(error)")
        }
        session.commitConfiguration()
        if let e = configError { throw e }

        // commit 之后：应用设备格式与帧率
        let fmt = format ?? Self.bestFormat(for: device)
        if let fmt { apply(format: fmt, to: device) }
        currentFormat = activeFormatDescriptor(device)
        configured = true

        session.startRunning()
        // 实测：startRunning 协商会把 activeVideoMinFrameDuration 重置回默认挡位。
        // OBS 的做法是在 session 运行中直接改 device 属性（hot update）——这里再钉一次。
        if let fmt { apply(format: fmt, to: device) }
        currentFormat = activeFormatDescriptor(device)
        // 回读 AVF 实际生效的格式（commit 后设备可能否决我们的请求——带宽不足时常见）
        let finalDims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let finalCodec = CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription)
        let finalDuration = device.activeVideoMinFrameDuration
        let finalFPS = finalDuration.isValid && finalDuration.value > 0
            ? Double(finalDuration.timescale) / Double(finalDuration.value) : 0
        NSLog("[CaptureStream] EFFECTIVE: %ldx%ld %@ @ %.3ffps (requested %@)",
              finalDims.width, finalDims.height,
              CaptureDeviceManager.pixelFormatName(finalCodec),
              finalFPS, format?.label ?? "default")
    }

    /// 面积最大的分辨率下帧率最高的组合（默认格式选择）。
    nonisolated static func bestFormat(for device: AVCaptureDevice) -> CaptureFormatDescriptor? {
        var best: (area: Int, fps: Int, fmt: CaptureFormatDescriptor)?
        for f in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard dims.width > 0, dims.height > 0 else { continue }
            let codec = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            let pf = CaptureDeviceManager.pixelFormatName(codec)
            for range in f.videoSupportedFrameRateRanges {
                let fps = Int(range.maxFrameRate.rounded())
                guard fps > 0 else { continue }
                let area = Int(dims.width) * Int(dims.height)
                if best == nil || area > best!.area || (area == best!.area && fps > best!.fps) {
                    best = (area, fps, CaptureFormatDescriptor(width: Int(dims.width),
                                                                height: Int(dims.height),
                                                                fps: fps, pixelFormat: pf))
                }
            }
        }
        return best?.fmt
    }

    public func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        frameQueue.clear()
        configured = false
    }

    /// 阻塞取帧（渲染线程调用）。
    public func nextFrame(timeout: Double? = nil) -> CapturedFrame? {
        frameQueue.pop(timeout: timeout)
    }

    public var pendingFrames: Int { frameQueue.count }
    public var queueOverflowCount: Int { frameQueue.overflowCount }

    // MARK: - 格式切换（分辨率/FPS/像素格式，§6）

    private func apply(format: CaptureFormatDescriptor, to device: AVCaptureDevice) {
        deviceRef = device
        // 匹配顺序：完全匹配 → 放宽像素格式 → 放宽帧率。绝不静默放弃——
        // 放弃会让设备停留出厂低帧率（4K 设备默认可能只有 25fps）。
        let match = device.formats.first { f in
            Self.matches(f, width: format.width, height: format.height,
                         fps: format.fps, pixelFormat: format.pixelFormat)
        } ?? device.formats.first { f in
            Self.matches(f, width: format.width, height: format.height,
                         fps: format.fps, pixelFormat: nil)
        } ?? device.formats.first { f in
            Self.matches(f, width: format.width, height: format.height,
                         fps: nil, pixelFormat: nil)
        }
        guard let match else {
            NSLog("[CaptureStream] no device format for \(format.label), keeping current")
            return
        }

        // 帧率锁定 min=max=目标时长：
        // 优先取"目标 fps 恰好落在区间内"的区间（min<=fps<=max），
        // 避免多区间设备（如 1-30 与 30-60 并存）first 命中低速区间。
        let desiredSec = 1.0 / Double(max(format.fps, 1))
        var targetDuration = CMTime(seconds: desiredSec, preferredTimescale: 600_000)
        var exactRange: AVFrameRateRange?
        for r in match.videoSupportedFrameRateRanges {
            guard r.minFrameDuration.isValid, r.maxFrameDuration.isValid else { continue }
            let minFps = 1.0 / (Double(r.maxFrameDuration.value) / Double(r.maxFrameDuration.timescale))
            let maxFps = 1.0 / (Double(r.minFrameDuration.value) / Double(r.minFrameDuration.timescale))
            if Double(format.fps) >= minFps - 0.5 && Double(format.fps) <= maxFps + 0.5 {
                exactRange = r
                break
            }
        }
        if let r = exactRange {
            // 目标时长若慢于区间最慢则用区间最慢；快于最快则用最快（NSException 保护）
            let fastestSec = Double(r.minFrameDuration.value) / Double(r.minFrameDuration.timescale)
            let slowestSec = Double(r.maxFrameDuration.value) / Double(r.maxFrameDuration.timescale)
            if desiredSec < fastestSec { targetDuration = r.minFrameDuration }
            else if desiredSec > slowestSec { targetDuration = r.maxFrameDuration }
        } else if let r = match.videoSupportedFrameRateRanges.first(where: { $0.minFrameDuration.isValid }) {
            // 无精确区间：钳到设备最快
            targetDuration = r.minFrameDuration
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = match
            device.activeVideoMinFrameDuration = targetDuration
            device.activeVideoMaxFrameDuration = targetDuration
            device.unlockForConfiguration()
            let actualFPS = 1.0 / (Double(targetDuration.value) / Double(targetDuration.timescale))
            NSLog("[CaptureStream] applied %@ @ %.4fs (%.2ffps)", Self.describe(match),
                  Double(targetDuration.value) / Double(targetDuration.timescale), actualFPS)
        } catch {
            NSLog("[CaptureStream] format lock failed: \(error)")
        }
    }

    /// 实际生效的帧率（apply 后读取，UI 显示用）。
    public var effectiveFPS: Double {
        sessionQueue.sync {
            let d = deviceRef?.activeVideoMinFrameDuration ?? CMTime.invalid
            guard d.isValid, d.value > 0 else { return 0 }
            return Double(d.timescale) / Double(d.value)
        }
    }
    /// 当前设备引用（诊断实时回读；线程安全只读属性访问）。
    public var device: AVCaptureDevice? { deviceRef }
    private weak var deviceRef: AVCaptureDevice?

    /// 格式匹配谓词（nil = 放宽该维度）。
    nonisolated static func matches(_ f: AVCaptureDevice.Format,
                                    width: Int, height: Int,
                                    fps: Int?, pixelFormat: String?) -> Bool {
        let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        guard Int(dims.width) == width, Int(dims.height) == height else { return false }
        if let pf = pixelFormat {
            let codec = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            guard CaptureDeviceManager.pixelFormatName(codec) == pf else { return false }
        }
        if let fps {
            return f.videoSupportedFrameRateRanges.contains {
                $0.maxFrameRate >= Double(fps) - 0.5 && $0.minFrameRate <= Double(fps) + 0.5
            }
        }
        return true
    }

    nonisolated static func describe(_ f: AVCaptureDevice.Format) -> String {
        let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let codec = CMFormatDescriptionGetMediaSubType(f.formatDescription)
        return "\(dims.width)x\(dims.height) \(CaptureDeviceManager.pixelFormatName(codec))"
    }

    private func activeFormatDescriptor(_ device: AVCaptureDevice) -> CaptureFormatDescriptor {
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let codec = CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription)
        var fps = 0
        if let r = device.activeFormat.videoSupportedFrameRateRanges.first,
           device.activeVideoMinFrameDuration.isValid {
            fps = Int((1.0 / Double(device.activeVideoMinFrameDuration.value) * Double(device.activeVideoMinFrameDuration.timescale)).rounded())
            _ = r
        }
        return CaptureFormatDescriptor(width: Int(dims.width), height: Int(dims.height),
                                       fps: max(fps, 0), pixelFormat: CaptureDeviceManager.pixelFormatName(codec))
    }

    private func permissionGranted() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined:
            let sema = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .video) { _ in sema.signal() }
            return sema.wait(timeout: .now() + 30) == .success
        default: return false
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard configured else { return }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        idLock.lock()
        frameCounter += 1
        let id = frameCounter
        _callbackFrameCount = frameCounter
        idLock.unlock()
        // 设备 PTS 实测帧率（区分"设备只送 25fps"vs"传输/渲染丢帧"）
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if pts.isValid, lastPTS.isValid, pts > lastPTS {
            let delta = CMTimeGetSeconds(CMTimeSubtract(pts, lastPTS))
            if delta > 0.001 {
                idLock.lock()
                _lastPTSDeltaSec = delta
                _ptsSamples += 1
                idLock.unlock()
            }
        }
        lastPTS = pts
        var trace = monitor?.recordCapture(frameID: id, at: now, pts: Int64(pts.value)) ??
                    FrameTrace(frameID: id, pts: Int64(pts.value), capturedAt: now)
        trace.capturedAt = now
        // capture → decode 直通（UVC 无解码），同线程标记
        monitor?.recordDecode(&trace, at: now)
        frameQueue.push(CapturedFrame(pixelBuffer: pb, trace: trace))
    }

    public func captureOutput(_ output: AVCaptureOutput,
                              didDrop sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        // AVCaptureVideoDataOutput 丢弃晚帧：transport/queue 级丢帧（§16）
        monitor?.noteAVFoundationDrop(at: CFAbsoluteTimeGetCurrent())
    }
}
#endif
