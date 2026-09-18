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
    private let queue = DispatchQueue(label: "capture.video", qos: .userInteractive)
    private let frameQueue: BoundedFrameQueue<CapturedFrame>

    public private(set) var currentFormat: CaptureFormatDescriptor?
    public var monitor: PerformanceMonitor?

    private var frameCounter: UInt64 = 0
    private let idLock = NSLock()
    private var configured = false

    public init(frameQueueCapacity: Int = 2,
                policy: BoundedFrameQueue<Int>.OverflowPolicy = .dropOldest) {
        super.init()
        frameQueue = BoundedFrameQueue<CapturedFrame>(capacity: frameQueueCapacity, policy: policy)
        output.videoSettings = [:]   // 原生格式输出，不做 CPU 转换（§5）
        output.alwaysDiscardsLateVideoFrames = true   // 低延迟：晚帧直接丢（§22）
        output.setSampleBufferDelegate(self, queue: queue)
    }

    /// 配置并启动。format 为 nil 时选设备默认最优格式。
    public func start(deviceID: String, format: CaptureFormatDescriptor?) throws {
        guard permissionGranted() else { throw CaptureSessionError.noPermission }
        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            throw CaptureSessionError.deviceNotFound(deviceID)
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)

        guard let input = try? AVCaptureDeviceInput(device: device) else {
            throw CaptureSessionError.cannotConfigure("cannot create device input")
        }
        guard session.canAddInput(input) else {
            throw CaptureSessionError.cannotConfigure("cannot add input")
        }
        session.addInput(input)

        if let fmt = format {
            apply(format: fmt, to: device)
        }
        currentFormat = activeFormatDescriptor(device)

        guard session.canAddOutput(output) else {
            throw CaptureSessionError.cannotConfigure("cannot add video output")
        }
        session.addOutput(output)
        session.sessionPreset = .inputPriority   // 尊重设备格式而非 preset 缩放（§5）
        configured = true
        session.startRunning()
    }

    public func stop() {
        queue.async { [session] in
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
        guard let match = device.formats.first(where: { f in
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard Int(dims.width) == format.width, Int(dims.height) == format.height else { return false }
            let codec = CMVideoFormatDescriptionGetCodecType(f.formatDescription)
            guard CaptureDeviceManager.pixelFormatName(codec) == format.pixelFormat else { return false }
            return f.videoSupportedFrameRateRanges.contains {
                Int($0.maxFrameRate.rounded()) == format.fps
            }
        }) else { return }   // 不支持的组合静默跳过（UI 只列出可用组合，§6）
        do {
            try device.lockForConfiguration()
            device.activeFormat = match
            let fps = Double(format.fps)
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.unlockForConfiguration()
        } catch {
            NSLog("[CaptureStream] format lock failed: \(error)")
        }
    }

    private func activeFormatDescriptor(_ device: AVCaptureDevice) -> CaptureFormatDescriptor {
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let codec = CMVideoFormatDescriptionGetCodecType(device.activeFormat.formatDescription)
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
        let now = CFAbsoluteTimeGetCurrent()   // 与渲染侧统一使用 CFAbsoluteTime 单调近似
        idLock.lock(); frameCounter += 1; let id = frameCounter; idLock.unlock()
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).value
        var trace = monitor?.recordCapture(frameID: id, at: now, pts: pts) ??
                    FrameTrace(frameID: id, pts: pts, capturedAt: now)
        trace.capturedAt = now
        // capture → decode 直通（UVC 无解码），同线程标记
        monitor?.recordDecode(&trace, at: now)
        frameQueue.push(CapturedFrame(pixelBuffer: pb, trace: trace))
    }

    public func captureOutput(_ output: AVCaptureOutput,
                              didDrop sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        // AVCaptureVideoDataOutput 丢弃晚帧：transport/queue 级丢帧（§16）
        monitor?.noteQueueDrop()
    }
}

extension PerformanceMonitor {
    /// 队列/transport 层丢帧打点（AVFoundation didDrop 回调）。
    public func noteQueueDrop() {
        lock.lock(); defer { lock.unlock() }
        drops[.capture, default: 0] += 1
        appendEvent(DropEvent(stage: .capture, reason: .queueOverflow,
                              at: CFAbsoluteTimeGetCurrent(),
                              expectedFrameID: lastFrameID,
                              detail: "AVFoundation dropped late frame"))
    }
}
#endif
