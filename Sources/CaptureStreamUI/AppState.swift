#if canImport(AppKit) && canImport(AVFoundation) && canImport(Metal)
import AppKit
import AVFoundation
import Combine
import Foundation
import Metal
import CaptureStreamCore

/// 应用状态中枢：设备选择 → 采集会话/测试图案 → 渲染循环 → 快照发布。
/// @MainActor：UI 层唯一可变状态源；视频热路径全在后台线程。
@MainActor
public final class AppState: ObservableObject {

    public static let testPatternID = "__testpattern__"

    // MARK: - Published（UI）

    @Published public var settings: AppSettings { didSet { persist(settings) } }
    @Published public var selectedDeviceID: String? { didSet { onSelectionChanged() } }
    @Published public var selectedFormatLabel: String? { didSet { onSelectionChanged() } }
    @Published public var isRunning = false { didSet { onRunChanged() } }
    @Published public var isFullscreen = false { didSet { onFullscreenChanged() } }
    @Published public var showSettings = false
    @Published public var latestSnapshot: PerformanceMonitor.Snapshot?
    @Published public var lastPresentedTrace: FrameTrace?
    @Published public var errorMessage: String?
    @Published public var isRecording = false
    @Published public var recordingRows = 0
    @Published public var frameTimeHistory: [Double] = []
    @Published public var sourceKind: VideoSourceKind = .device
    @Published public var activeFormat: CaptureFormatDescriptor?

    public let deviceManager = CaptureDeviceManager()
    public let monitor = PerformanceMonitor()

    // MARK: - 管线组件（后台）

    nonisolated public let renderQueue = BoundedFrameQueue<CapturedFrame>(capacity: 2, policy: .dropOldest)
    private var captureSession: VideoCaptureSession?
    private var testSource: TestPatternSource?
    private var renderLoop: RenderLoop?
    private var renderer: MetalRenderer?
    private var audio: AudioPipeline?
    private weak var metalLayer: CAMetalLayer?

    private var snapshotTimer: Timer?
    private var reconnectionAttempts = 0

    public var availableFormats: [String] {
        guard let id = selectedDeviceID, id != Self.testPatternID,
              let d = deviceManager.device(withID: id) else { return [] }
        return d.formats.map { $0.label }
    }

    public var deviceName: String {
        guard let id = selectedDeviceID else { return "No device" }
        if id == Self.testPatternID { return "Test Pattern" }
        return deviceManager.device(withID: id)?.name ?? "Unknown"
    }

    // MARK: - 初始化

    public init() {
        settings = SettingsStore.load()
        selectedDeviceID = settings.lastDeviceID
        selectedFormatLabel = settings.format?.label
        monitor.spikeThresholdMs = settings.spikeThresholdMs
        monitor.dropThresholdMs = settings.dropThresholdMs
        renderer = MetalRenderer()
        deviceManager.onDeviceChanged = { [weak self] in
            Task { @MainActor in self?.handleDeviceListChanged() }
        }
        if renderer == nil {
            errorMessage = "Metal initialization failed — GPU acceleration unavailable"
        }
    }

    private func persist(_ s: AppSettings) {
        SettingsStore.save(s)
        monitor.spikeThresholdMs = s.spikeThresholdMs
        monitor.dropThresholdMs = s.dropThresholdMs
        renderLoop?.updateSettings(SettingsMirror(
            scaling: s.scalingMode, filter: s.scaleFilter, aspect: s.aspectOverride,
            customScale: s.customScale, sharpen: s.sharpen, vsync: s.vsync))
        if let layer = metalLayer { layer.maximumDrawableCount = max(2, min(4, s.frameBufferCount)) }
        audio?.updateConfig(AudioPipeline.Config(
            outputDeviceID: s.audioOutputDeviceID, volume: s.audioVolume,
            muted: s.audioMuted, delayMs: s.audioDelayMs))
        if isRunning { restartPipeline() }
    }

    // MARK: - 视图层回调

    public func attach(layer: CAMetalLayer) {
        metalLayer = layer
        if let device = renderer?.device {
            layer.device = device
            layer.pixelFormat = .bgra8Unorm
            layer.framebufferOnly = true
            layer.maximumDrawableCount = settings.frameBufferCount
        }
    }

    public func viewportChanged(_ pointSize: CGSize) {
        renderLoop?.updateViewport(Size(width: Int(pointSize.width), height: Int(pointSize.height)))
    }

    private func onSelectionChanged() {
        settings.lastDeviceID = selectedDeviceID
        if let label = selectedFormatLabel,
           let id = selectedDeviceID,
           let d = deviceManager.device(withID: id),
           let f = d.formats.first(where: { $0.label == label }) {
            settings.format = f
        }
        if isRunning { restartPipeline() }
    }

    private func onRunChanged() {
        if isRunning { startPipeline() } else { stopPipeline() }
    }

    private func onFullscreenChanged() {
        // 全屏由 Window 组操作；此处只隐藏 UI（MainWindow 已按 isFullscreen 布局）
    }

    // MARK: - 管线生命周期

    private func startPipeline() {
        errorMessage = nil
        monitor.reset()
        guard let layer = metalLayer else { return }
        layer.maximumDrawableCount = settings.frameBufferCount

        if selectedDeviceID == Self.testPatternID {
            sourceKind = .testPattern
            let cfg = TestPatternSource.Config(width: 1920, height: 1080, fps: 60,
                                               pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            let src = TestPatternSource(config: cfg, queue: renderQueue)
            src.monitor = monitor
            testSource = src
            src.start()
            activeFormat = CaptureFormatDescriptor(width: 1920, height: 1080, fps: 60, pixelFormat: "NV12 (video)")
            monitor.targetFPS = 60
            monitor.currentResolution = Size(width: 1920, height: 1080)
            monitor.currentFormat = "NV12"
        } else {
            guard let deviceID = selectedDeviceID else {
                errorMessage = "No capture device selected"
                isRunning = false
                return
            }
            sourceKind = .device
            let format = settings.format
            let session = VideoCaptureSession(frameQueueCapacity: settings.latencyMode.recommendedQueueCapacity,
                                              policy: settings.latencyMode.recommendedPolicy)
            session.monitor = monitor
            do {
                try session.start(deviceID: deviceID, format: format)
            } catch {
                errorMessage = "\(error)"
                isRunning = false
                scheduleReconnect()
                return
            }
            captureSession = session
            activeFormat = session.currentFormat
            if let f = session.currentFormat {
                monitor.targetFPS = Double(f.fps)
                monitor.currentResolution = Size(width: f.width, height: f.height)
                monitor.currentFormat = f.pixelFormat
            }
            // 音频
            if settings.audioOutputDeviceID != nil || !settings.audioMuted {
                let ap = AudioPipeline(config: AudioPipeline.Config(
                    outputDeviceID: settings.audioOutputDeviceID,
                    volume: settings.audioVolume,
                    muted: settings.audioMuted,
                    delayMs: settings.audioDelayMs))
                try? ap.startPlayback()
                ap.attach(to: session.session, deviceID: audioInputDeviceID(for: deviceID))
                audio = ap
            }
        }

        // 渲染循环（设置通过镜像同步，避免渲染线程跨 MainActor 读取）
        let s = settings
        let loop = RenderLoop(renderer: renderer)
        loop.capture = captureSession
        loop.testQueue = sourceKind == .testPattern ? renderQueue : nil
        loop.monitor = monitor
        loop.layer = metalLayer
        loop.updateSettings(SettingsMirror(
            scaling: s.scalingMode, filter: s.scaleFilter, aspect: s.aspectOverride,
            customScale: s.customScale, sharpen: s.sharpen, vsync: s.vsync))
        renderLoop = loop
        loop.start()

        startSnapshotTimer()
        reconnectionAttempts = 0
    }

    private func stopPipeline() {
        renderLoop?.stop()
        renderLoop = nil
        testSource?.stop()
        testSource = nil
        captureSession?.stop()
        captureSession = nil
        audio?.stopPlayback()
        audio = nil
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        latestSnapshot = nil
    }

    private func restartPipeline() {
        stopPipeline()
        if isRunning { startPipeline() }
    }

    private func audioInputDeviceID(for videoDeviceID: String) -> String? {
        // 多数采集卡音频实体名称包含相同厂商串；无法精确对应时返回 nil 让 AVFoundation 自动选
        return nil
    }

    // MARK: - 快照定时器（§64：UI 5Hz）

    private func startSnapshotTimer() {
        snapshotTimer?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pullSnapshot() }
        }
        RunLoop.main.add(t, forMode: .common)
        snapshotTimer = t
    }

    private func pullSnapshot() {
        let snap = monitor.snapshot()
        latestSnapshot = snap
        // 帧时间历史（overlay 图）
        if let ft = snap.frameTime {
            frameTimeHistory.append(ft.avgMs)
            if frameTimeHistory.count > 300 { frameTimeHistory.removeFirst() }
        }
        recordingRows = monitor.recordingRowCount
        monitor.tickRecord(t: CFAbsoluteTimeGetCurrent())
    }

    // MARK: - 录制 / 导出（§19, §67）

    public func toggleRecording() {
        if isRecording {
            monitor.stopRecording()
            isRecording = false
        } else {
            monitor.startRecording()
            isRecording = true
        }
    }

    public func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "capturestream-\(Int(Date().timeIntervalSince1970)).csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? monitor.exportCSV().write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "capturestream-\(Int(Date().timeIntervalSince1970)).json"
        if panel.runModal() == .OK, let url = panel.url {
            try? monitor.exportJSON().write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 热插拔 / 断开恢复（§39-§41）

    private func handleDeviceListChanged() {
        objectWillChange.send()
        if isRunning, sourceKind == .device,
           let id = selectedDeviceID,
           deviceManager.device(withID: id) == nil {
            errorMessage = "Capture device disconnected — waiting for reconnect…"
            stopPipelineKeepRunning()
            scheduleReconnect()
        }
    }

    private func stopPipelineKeepRunning() {
        renderLoop?.stop(); renderLoop = nil
        captureSession?.stop(); captureSession = nil
        audio?.stopPlayback(); audio = nil
        testSource?.stop(); testSource = nil
        snapshotTimer?.invalidate(); snapshotTimer = nil
    }

    private func scheduleReconnect() {
        guard settings.autoReconnect, reconnectionAttempts < 60 else { return }
        reconnectionAttempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.isRunning || self.sourceKind == .device else { return }
            if let id = self.selectedDeviceID, self.deviceManager.device(withID: id) != nil {
                self.errorMessage = nil
                self.isRunning = true
                self.startPipeline()
            } else {
                self.scheduleReconnect()
            }
        }
    }
}

/// 渲染线程的设置镜像（避免渲染线程跨 MainActor 读 SwiftUI 状态）。
public struct SettingsMirror: Sendable {
    public var scaling: ScalingMode
    public var filter: ScaleFilter
    public var aspect: AspectRatioMode
    public var customScale: Double
    public var sharpen: Double
    public var vsync: Bool
    public init(scaling: ScalingMode, filter: ScaleFilter, aspect: AspectRatioMode,
                customScale: Double, sharpen: Double, vsync: Bool) {
        self.scaling = scaling; self.filter = filter; self.aspect = aspect
        self.customScale = customScale; self.sharpen = sharpen; self.vsync = vsync
    }
}
#endif
