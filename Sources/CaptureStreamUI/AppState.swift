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

    /// 程序化联动中抑制 didSet 重入（防 format↔fps 互相触发无限递归）。
    private var syncingSelection = false

    @Published public var settings: AppSettings { didSet { persist(settings) } }
    @Published public var selectedDeviceID: String? { didSet { onDevicePicked() } }
    @Published public var selectedFormatLabel: String? {
        didSet {
            guard !syncingSelection else { return }
            onFormatPicked()
        }
    }
    @Published public var selectedFPS: Int? {
        didSet {
            guard !syncingSelection else { return }
            onFPSPicked()
        }
    }
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

    /// 当前设备支持的唯一分辨率挡位（宽x高 去重，面积降序）。
    public var availableResolutions: [String] {
        guard let id = selectedDeviceID, id != Self.testPatternID,
              let d = deviceManager.device(withID: id) else { return [] }
        var seen = Set<String>()
        let res = d.formats.compactMap { f -> (String, Int)? in
            let key = "\(f.width)x\(f.height)"
            return seen.insert(key).inserted ? (key, f.width * f.height) : nil
        }
        return res.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    /// 当前分辨率下可选帧率（去重降序）。
    public var availableFPS: [Int] {
        guard let id = selectedDeviceID, id != Self.testPatternID,
              let d = deviceManager.device(withID: id),
              let fmt = settings.format else { return [] }
        let key = "\(fmt.width)x\(fmt.height)"
        var fps = Set<Int>()
        for f in d.formats where "\(f.width)x\(f.height)" == key {
            fps.insert(f.fps)
        }
        return fps.sorted(by: >)
    }

    public var deviceName: String {
        guard let id = selectedDeviceID else { return "未选择设备" }
        if id == Self.testPatternID { return "测试图案" }
        return deviceManager.device(withID: id)?.name ?? "未知设备"
    }

    /// 队列状态（诊断 FPS=0 用：帧是否到达渲染队列）。
    public var pendingFramesLabel: String {
        guard isRunning else { return "—" }
        guard let s = captureSession else {
            return sourceKind == .testPattern ? "…" : "—"
        }
        let n = s.pendingFrames
        return n >= 2 ? "满" : "\(n)"
    }

    /// 各级帧计数（上次快照以来增量），诊断帧卡在哪一级。
    @Published public var pipelineCounts = (callback: UInt64(0), rendered: UInt64(0), presented: UInt64(0))
    private var lastCounts = (callback: UInt64(0), rendered: UInt64(0), presented: UInt64(0))

    /// 管线运行日志（最近 200 行，设置页可导出）。
    @Published public var pipelineLog: [String] = []
    public func log(_ s: String) {
        pipelineLog.append(s)
        if pipelineLog.count > 200 { pipelineLog.removeFirst(pipelineLog.count - 200) }
    }

    /// 设备 PTS 实测输出帧率（采样自最近帧间隔）。
    public var measuredInputFPSLabel: String {
        guard let s = captureSession else { return "—" }
        let f = s.measuredInputFPS
        return f > 0 ? String(format: "%.2f fps", f) : "等待帧…"
    }

    /// dump 当前设备全部格式能力到日志（诊断 4K 支持什么帧率的决定性证据）。
    public func dumpDeviceCapabilities() {
        guard let id = selectedDeviceID, id != Self.testPatternID else {
            log("未选择真实设备")
            return
        }
        log("── 设备能力清单: \(deviceName) ──")
        if let d = deviceManager.device(withID: id) {
            for f in d.formats {
                log("  \(f.label)")
            }
        }
        if let s = captureSession {
            log(String(format: "当前会话: 设备实测 %.2f fps", s.measuredInputFPS))
        }
        log("── 清单结束 ──")
    }

    /// App 版本（bundle Info.plist，CI 注入日期+SHA）。
    public static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    #if canImport(MetalFX)
    /// MetalFX 可用性（启动时检测一次，如实报告）。
    public var metalFXStatus: String {
        guard renderer?.device != nil else { return "不可用（无 Metal 设备）" }
        // 输入输出格式支持由 scaler 创建时判定；此处报框架级可用性
        return "可用（Apple Silicon GPU）"
    }
    #else
    public var metalFXStatus: String { "本构建未包含 MetalFX" }
    #endif

    /// 插帧统计：原生 vs 实际渲染 FPS + 累计插帧数。
    public var interpolationLabel: String {
        guard let snap = latestSnapshot else { return "—" }
        let interp = renderLoop?.interpolatedCount ?? 0
        return String(format: "原生 %.1f · 渲染 %.1f · 插帧 %d 帧",
                      snap.captureFPS, snap.renderFPS, Int(interp))
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
            customScale: s.customScale, sharpen: s.sharpen, vsync: s.vsync,
            interpolation: s.frameInterpolation, superResolution: s.superResolution))
        if let layer = metalLayer { layer.maximumDrawableCount = max(2, min(4, s.frameBufferCount)) }
        audio?.updateConfig(AudioPipeline.Config(
            outputDeviceID: s.audioOutputDeviceID, volume: s.audioVolume,
            muted: s.audioMuted, delayMs: s.audioDelayMs))
        audio?.inputVolume = Float(s.audioInputVolume)
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

    /// 设备变化：格式立即联动默认值（避免停留在不匹配的旧格式）。
    private func onDevicePicked() {
        settings.lastDeviceID = selectedDeviceID
        guard let id = selectedDeviceID else {
            syncingSelection = true
            selectedFormatLabel = nil
            selectedFPS = nil
            syncingSelection = false
            settings.format = nil
            if isRunning { isRunning = false }
            return
        }
        if id == Self.testPatternID {
            let f = CaptureFormatDescriptor(width: 1920, height: 1080, fps: 60, pixelFormat: "NV12")
            syncingSelection = true
            settings.format = f
            selectedFormatLabel = f.label
            selectedFPS = 60
            syncingSelection = false
        } else if let d = deviceManager.device(withID: id) {
            // 已选格式仍属于该设备 → 保留；否则取默认（最大面积，偏好 ≥50fps 与 NV12）
            let keep = selectedFormatLabel.flatMap { label in d.formats.first { $0.label == label } }
            syncingSelection = true
            if let keep {
                settings.format = keep
            } else {
                let best = d.formats.first(where: { $0.fps >= 50 && $0.pixelFormat.contains("NV12") })
                    ?? d.formats.first(where: { $0.fps >= 50 })
                    ?? d.formats.first
                settings.format = best
                selectedFormatLabel = best?.label
            }
            selectedFPS = settings.format?.fps
            syncingSelection = false
        }
        if isRunning { restartPipeline() }
    }

    /// 格式变化（用户在 UI 手动选）：同步 fps 显示 + 需要时重启。
    private func onFormatPicked() {
        guard let id = selectedDeviceID, id != Self.testPatternID,
              let d = deviceManager.device(withID: id),
              let label = selectedFormatLabel,
              let f = d.formats.first(where: { $0.label == label }) else {
            if selectedFormatLabel == nil { settings.format = nil }
            return
        }
        settings.format = f
        syncingSelection = true
        selectedFPS = f.fps
        syncingSelection = false
        if isRunning { restartPipeline() }
    }

    /// 帧率变化（用户在 UI 手动选）：同分辨率重建 format。
    private func onFPSPicked() {
        guard let fps = selectedFPS,
              let id = selectedDeviceID, id != Self.testPatternID,
              let d = deviceManager.device(withID: id),
              let cur = settings.format else { return }
        let candidates = d.formats.filter { $0.width == cur.width && $0.height == cur.height && $0.fps == fps }
        if let keep = candidates.first(where: { $0.pixelFormat == cur.pixelFormat }) ?? candidates.first {
            settings.format = keep
            syncingSelection = true
            selectedFormatLabel = keep.label
            syncingSelection = false
            if isRunning { restartPipeline() }
        }
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
        layer.maximumDrawableCount = max(2, min(3, settings.frameBufferCount))   // CAMetalLayer 支持 2-4

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
            startRenderLoopAndTimers()
        } else {
            guard let deviceID = selectedDeviceID else {
                errorMessage = "No capture device selected"
                isRunning = false
                return
            }
            sourceKind = .device
            let format = settings.format
            let capacity = settings.latencyMode.recommendedQueueCapacity
            let policy = settings.latencyMode.recommendedPolicy
            // startRunning 可能阻塞数百毫秒（含权限弹窗），移出主线程避免 UI 卡死
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let session = VideoCaptureSession(frameQueueCapacity: capacity, policy: policy)
                session.monitor = self.monitor
                do {
                    try session.start(deviceID: deviceID, format: format)
                } catch {
                    Task { @MainActor in
                        self.errorMessage = "\(error)"
                        self.isRunning = false
                        self.scheduleReconnect()
                    }
                    return
                }
                Task { @MainActor in
                    guard self.isRunning else {
                        session.stop()   // 等待期间用户已 Stop
                        return
                    }
                    self.captureSession = session
                    self.activeFormat = session.currentFormat
                    if let f = session.currentFormat {
                        self.monitor.targetFPS = Double(f.fps)
                        self.monitor.currentResolution = Size(width: f.width, height: f.height)
                        self.monitor.currentFormat = f.pixelFormat
                    }
                    // 实际生效帧率（区分"请求 60"与"设备实际给出"）
                    let eff = session.effectiveFPS
                    self.log(String(format: "会话启动 · 请求 %@ · 实际 %.2f fps · %@",
                                    format?.label ?? "默认", eff,
                                    session.currentFormat?.label ?? "?"))
                    // 音频（session 操作走 sessionQueue 与视频互斥）
                    if self.settings.audioOutputDeviceID != nil || !self.settings.audioMuted {
                        let ap = AudioPipeline(config: AudioPipeline.Config(
                            outputDeviceID: self.settings.audioOutputDeviceID,
                            volume: self.settings.audioVolume,
                            muted: self.settings.audioMuted,
                            delayMs: self.settings.audioDelayMs))
                        try? ap.startPlayback()
                        // 输入源：用户显式选择 > 自动按视频设备匹配 > 第一个外置
                        let inputID = self.settings.audioInputDeviceID
                            ?? self.audioInputDeviceID(for: deviceID)
                        ap.inputVolume = Float(self.settings.audioInputVolume)
                        ap.attach(to: session.session, sessionQueue: session.sessionQueue,
                                  deviceID: inputID)
                        self.audio = ap
                        self.log("音频输入: \(inputID ?? "自动") · 输出: \(self.settings.audioOutputDeviceID ?? "系统默认")")
                    }
                    self.startRenderLoopAndTimers()
                }
            }
        }
    }

    private func startRenderLoopAndTimers() {
        let s = settings
        let loop = RenderLoop(renderer: renderer)
        loop.capture = captureSession
        loop.testQueue = sourceKind == .testPattern ? renderQueue : nil
        loop.monitor = monitor
        loop.layer = metalLayer
        loop.updateSettings(SettingsMirror(
            scaling: s.scalingMode, filter: s.scaleFilter, aspect: s.aspectOverride,
            customScale: s.customScale, sharpen: s.sharpen, vsync: s.vsync,
            interpolation: s.frameInterpolation, superResolution: s.superResolution))
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
        lastCounts = (0, 0, 0)   // 会话重启计数器归零，防下溢
    }

    private func restartPipeline() {
        stopPipeline()
        if isRunning { startPipeline() }
    }

    private func audioInputDeviceID(for videoDeviceID: String) -> String? {
        // 采集卡的音频实体名称通常与视频实体同前缀（如 "UVC Camera" / "HD Webcam"）
        guard let video = deviceManager.device(withID: videoDeviceID) else { return nil }
        let vName = video.name.lowercased()
        // 取厂商关键词（前两个词）匹配
        let keys = vName.split(separator: " ").prefix(2).map(String.init)
        let externals = deviceManager.audioDevices.filter { d in
            let n = d.name.lowercased()
            return !n.contains("built-in") && !n.contains("macbook") && !n.contains("内建")
        }
        for d in externals {
            let n = d.name.lowercased()
            if keys.contains(where: { n.contains($0) && $0.count > 2 }) { return d.id }
        }
        return externals.first?.id   // 唯一外置音频设备时直接用它
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

        // 诊断计数（每 2s 报告一次增量到日志）
        // 注意：切换格式/帧率会重启会话，计数器归零——无符号减法必须饱和（下溢会 trap）
        let cb = captureSession?.callbackFrameCount ?? 0
        let rd = monitor.renderedCount
        let pr = monitor.presentedCount
        pipelineCounts = (cb, rd, pr)
        func satSub(_ a: UInt64, _ b: UInt64) -> Int { a >= b ? Int(a - b) : Int(a) }
        if cb > 0 || rd > 0 || pr > 0 || isRunning {
            if abs(CFAbsoluteTimeGetCurrent() - lastDiagAt) > 2.0 {
                lastDiagAt = CFAbsoluteTimeGetCurrent()
                let dcb = satSub(cb, lastCounts.callback)
                let drd = satSub(rd, lastCounts.rendered)
                let dpr = satSub(pr, lastCounts.presented)
                if dcb == 0 && isRunning {
                    log("⚠ 采集回调 2s 内 0 帧（检查：信号源开启/HDMI线/设备未被其他App占用/相机权限）")
                } else if dcb > 0 && drd == 0 {
                    log("⚠ 回调有帧(\(dcb)/2s)但渲染 0 帧（渲染循环/纹理问题）")
                } else if drd > 0 && dpr == 0 {
                    log("⚠ 渲染有帧(\(drd)/2s)但呈现 0 帧（drawable/present 问题）")
                }
                lastCounts = (cb, rd, pr)
            }
        }
    }
    private var lastDiagAt: Double = 0

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
        lastCounts = (0, 0, 0)
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
    public var interpolation: Bool
    public var superResolution: Bool
    public init(scaling: ScalingMode, filter: ScaleFilter, aspect: AspectRatioMode,
                customScale: Double, sharpen: Double, vsync: Bool,
                interpolation: Bool = false, superResolution: Bool = false) {
        self.scaling = scaling; self.filter = filter; self.aspect = aspect
        self.customScale = customScale; self.sharpen = sharpen; self.vsync = vsync
        self.interpolation = interpolation; self.superResolution = superResolution
    }
}
#endif
