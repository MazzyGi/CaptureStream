import Foundation

/// 全管线性能监视器：每阶段 FPS + 帧序列号连续性掉帧检测 + 帧时间统计（规范 §13-§17, §60-§63）。
/// 线程安全；每帧只做 O(1) 追加，统计按需计算，UI 以 5-10Hz 拉取快照（规范 §64）。
public final class PerformanceMonitor: @unchecked Sendable {

    public struct Snapshot: Sendable {
        public var captureFPS: Double
        public var decodeFPS: Double
        public var processFPS: Double
        public var renderFPS: Double
        public var presentFPS: Double
        public var dropsByStage: [PipelineStage: Int]
        public var totalDrops: Int
        public var frameTime: FrameTimeStats?
        public var e2eLatencyMs: Double?          // capture → present
        public var renderLatencyMs: Double?
        public var duplicateFrames: Int
        public var lastFrameID: UInt64
        public var inputResolution: Size?
        public var pixelFormat: String?
        public var warnings: [String]
    }

    private let lock = NSLock()
    private let counters: [PipelineStage: StageCounter]
    private let window: Double

    // 帧序列号连续性
    private var lastFrameID: UInt64 = 0
    private var haveLastFrame = false
    private var duplicateFrames = 0

    // 各阶段掉帧计数
    private var drops: [PipelineStage: Int] = [:]

    // 最近帧间隔（用于帧时间统计）
    private var intervalsMs: [Double] = []
    private let maxIntervals = 600

    // 最近完成的帧 trace（计算延迟）
    private var recentTraces: [FrameTrace] = []
    private let maxTraces = 240

    // 帧时间阈值（§63，可配置）
    public var spikeThresholdMs: Double
    public var dropThresholdMs: Double
    private var spikeCount = 0

    // CSV 记录（§18-§19，环形缓冲 + 批量导出）
    private var csvRows: [(t: Double, snap: Snapshot)] = []
    private let maxCSVRows = 3600 * 60      // ~1h @ 60Hz 上限
    private var recording = false
    private var lastSnapshotAt: Double = 0

    public init(window: Double = 1.0,
                spikeThresholdMs: Double = 25,
                dropThresholdMs: Double = 33) {
        self.window = window
        self.spikeThresholdMs = spikeThresholdMs
        self.dropThresholdMs = dropThresholdMs
        var c: [PipelineStage: StageCounter] = [:]
        for s in PipelineStage.allCases { c[s] = StageCounter(window: window) }
        counters = c
    }

    // MARK: - 每帧打点（热路径，O(1)）

    /// 采集到一帧（含设备帧序列号/PTS）。在 capture 回调线程调用。
    public func recordCapture(frameID: UInt64, at t: Double, pts: Int64 = 0) -> FrameTrace {
        var trace = FrameTrace(frameID: frameID, pts: pts)
        trace.capturedAt = t
        lock.lock(); defer { lock.unlock() }
        counters[.capture]?.record(t)

        if haveLastFrame {
            if frameID == lastFrameID {
                duplicateFrames += 1
            } else if frameID > lastFrameID + 1 {
                let missing = frameID - lastFrameID - 1
                let gapMs = (t - lastCaptureAt) * 1000
                // 期望帧间隔（按目标 FPS，无目标时退回 drop 阈值）
                let expectedIntervalMs = targetFPS > 1 ? 1000.0 / targetFPS : dropThresholdMs
                // 间隔明显超出缺失帧数应有的时间（2.5 倍余量吸收抖动/浮点边界）
                // 准点到达但 ID 跳变（gap ≈ (missing+1)×间隔）→ transport drop；
                // 间隔远超（如设备停流）→ capture drop
                let reason: DropReason = gapMs > Double(missing + 1) * expectedIntervalMs * 2.5 ? .captureDrop : .transportDrop
                drops[.capture, default: 0] += Int(missing)
                appendEvent(DropEvent(stage: .capture, reason: reason, at: t,
                                      expectedFrameID: lastFrameID + 1, receivedFrameID: frameID,
                                      detail: "missing \(missing) frame(s), gap \(String(format: "%.1f", gapMs))ms"))
            }
            intervalsMs.append((t - lastCaptureAt) * 1000)
            if intervalsMs.count > maxIntervals { intervalsMs.removeFirst(intervalsMs.count - maxIntervals) }
            let last = intervalsMs.last!
            if last > dropThresholdMs { spikeCount += 1; appendEvent(DropEvent(stage: .capture, reason: .possibleDroppedFrame, at: t, expectedFrameID: frameID, detail: "interval \(String(format: "%.1f", last))ms")) }
            else if last > spikeThresholdMs { spikeCount += 1; appendEvent(DropEvent(stage: .capture, reason: .frameTimeSpike, at: t, expectedFrameID: frameID, detail: "interval \(String(format: "%.1f", last))ms")) }
        }
        lastFrameID = frameID
        haveLastFrame = true
        warmupFrames += 1
        lastCaptureAt = t
        return trace
    }

    private var lastCaptureAt: Double = 0

    public func recordDecode(_ trace: inout FrameTrace, at t: Double) {
        trace.decodedAt = t
        lock.lock(); defer { lock.unlock() }
        counters[.decode]?.record(t)
        trackStageDrop(from: .capture, to: .decode, at: t)
    }

    public func recordProcess(_ trace: inout FrameTrace, at t: Double) {
        trace.processedAt = t
        lock.lock(); defer { lock.unlock() }
        counters[.process]?.record(t)
        trackStageDrop(from: .decode, to: .process, at: t)
    }

    public func recordRender(_ trace: inout FrameTrace, at t: Double) {
        trace.renderedAt = t
        lock.lock(); defer { lock.unlock() }
        counters[.render]?.record(t)
        trackStageDrop(from: .process, to: .render, at: t)
        recentTraces.append(trace)
        if recentTraces.count > maxTraces { recentTraces.removeFirst(recentTraces.count - maxTraces) }
    }

    public func recordPresent(_ trace: FrameTrace, at t: Double) {
        // struct 传入为值语义，直接补 presentedAt 用于延迟计算
        lock.lock(); defer { lock.unlock() }
        counters[.present]?.record(t)
        trackStageDrop(from: .render, to: .present, at: t)
        if let idx = recentTraces.lastIndex(where: { $0.frameID == trace.frameID }) {
            recentTraces[idx].presentedAt = t
        }
    }

    /// 阶段间 FPS 差 → 掉帧归因（§62 的"可能原因"提示在 warnings 生成）。
    /// 注意：相邻阶段每帧各打一次点，计数差在窗口边界可能有 ±1 抖动，
    /// 因此只有持续差值（>2 帧/窗口）才计入 drops。
    /// warmupFrames：启动初期各阶段计数未对齐，跳过判定避免伪事件。
    private var warmupFrames = 0
    private func trackStageDrop(from: PipelineStage, to: PipelineStage, at t: Double) {
        // 两阶段都累积足够样本后才做差值判定（抑制启动/边界伪事件）
        guard let fC = counters[from], let gC = counters[to] else { return }
        guard fC.hasEnoughSamples, gC.hasEnoughSamples else { return }
        guard let f = counters[from]?.fps, let g = counters[to]?.fps else { return }
        let deficit = f - g
        if deficit > 2.0 {
            let reason: DropReason
            switch to {
            case .decode: reason = .decodeDrop
            case .process: reason = .decodeDrop
            case .render: reason = .renderDrop
            case .present: reason = .presentDrop
            case .capture: reason = .captureDrop
            }
            drops[to, default: 0] += 0   // 计数由序列号/队列路径负责，这里只留事件
            appendEvent(DropEvent(stage: to, reason: reason, at: t,
                                  expectedFrameID: lastFrameID,
                                  detail: String(format: "%@ %.1f → %@ %.1f", from.rawValue, f, to.rawValue, g)))
        }
    }

    // MARK: - 事件日志

    private var events: [DropEvent] = []
    private let maxEvents = 512
    private func appendEvent(_ e: DropEvent) {
        events.append(e)
        if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
    }

    public func recentEvents() -> [DropEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    /// AVFoundation 丢弃晚帧打点（queue/transport 级丢帧，§16）。
    public func noteAVFoundationDrop(at t: Double) {
        lock.lock(); defer { lock.unlock() }
        drops[.capture, default: 0] += 1
        appendEvent(DropEvent(stage: .capture, reason: .queueOverflow,
                              at: t, expectedFrameID: lastFrameID,
                              detail: "AVFoundation dropped late frame"))
    }

    // MARK: - 快照（UI 5-10Hz 拉取）

    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let latencies = recentTraces.compactMap { tr -> Double? in
            guard let c = tr.capturedAt, let p = tr.presentedAt else { return nil }
            return (p - c) * 1000
        }
        let renderLat = recentTraces.compactMap { tr -> Double? in
            guard let r = tr.renderedAt, let p = tr.presentedAt else { return nil }
            return (p - r) * 1000
        }
        var snap = Snapshot(
            captureFPS: counters[.capture]?.fps ?? 0,
            decodeFPS: counters[.decode]?.fps ?? 0,
            processFPS: counters[.process]?.fps ?? 0,
            renderFPS: counters[.render]?.fps ?? 0,
            presentFPS: counters[.present]?.fps ?? 0,
            dropsByStage: drops,
            totalDrops: drops.values.reduce(0, +),
            frameTime: FrameTimeStats.compute(from: intervalsMs),
            e2eLatencyMs: latencies.isEmpty ? nil : latencies.suffix(60).reduce(0, +) / Double(latencies.suffix(60).count),
            renderLatencyMs: renderLat.isEmpty ? nil : renderLat.suffix(60).reduce(0, +) / Double(renderLat.count),
            duplicateFrames: duplicateFrames,
            lastFrameID: lastFrameID,
            inputResolution: currentResolution,
            pixelFormat: currentFormat,
            warnings: []
        )
        // 自动诊断（§62）：只标"可能"
        let inFps = snap.captureFPS
        if inFps > 1, snap.decodeFPS < inFps - 2 { snap.warnings.append("⚠ Possible Decode Bottleneck (input \(fmt(inFps)) → decode \(fmt(snap.decodeFPS)))") }
        if snap.decodeFPS > 1, snap.processFPS < snap.decodeFPS - 2 { snap.warnings.append("⚠ Possible Process Bottleneck") }
        if snap.processFPS > 1, snap.renderFPS < snap.processFPS - 2 { snap.warnings.append("⚠ Possible Render Bottleneck (process \(fmt(snap.processFPS)) → render \(fmt(snap.renderFPS)))") }
        if snap.renderFPS > 1, snap.presentFPS < snap.renderFPS - 2 { snap.warnings.append("⚠ Possible Present/Display Bottleneck") }
        if inFps > 1, inFps < targetFPS - 2 { snap.warnings.append("⚠ Possible Capture Drop (input \(fmt(inFps)) < target \(fmt(targetFPS)))") }
        return snap
    }

    public var targetFPS: Double = 60
    public var currentResolution: Size?
    public var currentFormat: String?

    private func fmt(_ v: Double) -> String { String(format: "%.1f", v) }

    // MARK: - CSV 记录（§18-§19）

    public func startRecording() {
        lock.lock(); defer { lock.unlock() }
        recording = true
        csvRows.removeAll()
    }

    public func stopRecording() {
        lock.lock(); defer { lock.unlock() }
        recording = false
    }

    /// 当前录制的快照行数（UI 显示）。
    public var recordingRowCount: Int {
        lock.lock(); defer { lock.unlock() }
        return csvRows.count
    }

    /// 以固定频率记录快照（由 UI timer 5-10Hz 驱动，非每帧）。
    public func tickRecord(t: Double) {
        lock.lock()
        let should = recording
        if should, !csvRows.isEmpty || t - lastSnapshotAt >= 0.2 {
            lastSnapshotAt = t
        }
        lock.unlock()
        guard should else { return }
        let snap = snapshot()
        lock.lock()
        csvRows.append((t, snap))
        if csvRows.count > maxCSVRows { csvRows.removeFirst(csvRows.count - maxCSVRows) }
        lock.unlock()
    }

    public func exportCSV() -> String {
        lock.lock(); defer { lock.unlock() }
        var lines = ["timestamp,capture_fps,decode_fps,process_fps,render_fps,present_fps,dropped,duplicates,frame_time_avg_ms,frame_time_p95_ms,frame_time_p99_ms,e2e_latency_ms,render_latency_ms"]
        for row in csvRows {
            let s = row.snap
            lines.append(String(format: "%.3f,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%d,%.2f,%.2f,%.2f,%.2f,%.2f",
                row.t, s.captureFPS, s.decodeFPS, s.processFPS, s.renderFPS, s.presentFPS,
                s.totalDrops, s.duplicateFrames,
                s.frameTime?.avgMs ?? -1, s.frameTime?.p95Ms ?? -1, s.frameTime?.p99Ms ?? -1,
                s.e2eLatencyMs ?? -1, s.renderLatencyMs ?? -1))
        }
        return lines.joined(separator: "\n")
    }

    /// JSON 导出（含事件日志，§19）。
    public func exportJSON() -> String {
        lock.lock(); defer { lock.unlock() }
        var obj: [String: Any] = [:]
        obj["events"] = events.map { e -> [String: Any] in
            ["stage": e.stage.rawValue, "reason": e.reason.rawValue, "at": e.at,
             "expected": e.expectedFrameID, "received": e.receivedFrameID.map(Int64.init) ?? -1, "detail": e.detail]
        }
        obj["rows"] = csvRows.map { r -> [String: Any] in
            ["t": r.t, "captureFPS": r.snap.captureFPS, "decodeFPS": r.snap.decodeFPS,
             "renderFPS": r.snap.renderFPS, "presentFPS": r.snap.presentFPS,
             "dropped": r.snap.totalDrops, "duplicates": r.snap.duplicateFrames,
             "latencyMs": r.snap.e2eLatencyMs ?? -1]
        }
        obj["spikeCount"] = spikeCount
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) { return str }
        return "{}"
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        for c in counters.values { c.reset() }
        drops = [:]
        events = []
        intervalsMs = []
        recentTraces = []
        duplicateFrames = 0
        haveLastFrame = false
        spikeCount = 0
        warmupFrames = 0
    }
}
