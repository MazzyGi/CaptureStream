import XCTest
@testable import CaptureStreamCore

final class FrameDropTests: XCTestCase {

    /// 模拟完美 60FPS 流 120 帧 → 无掉帧、FPS≈60。
    func testPerfectStreamNoDrops() {
        let m = PerformanceMonitor()
        m.targetFPS = 60
        let dt = 1.0 / 60.0
        for i in 0..<120 {
            let t = Double(i) * dt
            var tr = m.recordCapture(frameID: UInt64(i), at: t)
            m.recordDecode(&tr, at: t + 0.001)
            m.recordProcess(&tr, at: t + 0.0015)
            m.recordRender(&tr, at: t + 0.002)
            m.recordPresent(tr, at: t + 0.003)
        }
        let snap = m.snapshot()
        XCTAssertEqual(snap.totalDrops, 0)
        XCTAssertEqual(snap.captureFPS, 60, accuracy: 1.0)
        XCTAssertEqual(snap.renderFPS, 60, accuracy: 1.0)
        XCTAssertTrue(snap.warnings.isEmpty, "warnings: \(snap.warnings)")
        if let ft = snap.frameTime {
            XCTAssertEqual(ft.avgMs, 16.67, accuracy: 0.5)
        } else { XCTFail("no frame time stats") }
    }

    /// 输入序列号跳变（100 缺失，间隔正常）→ transport drop。
    func testCaptureSequenceGapDetected() {
        let m = PerformanceMonitor()
        m.targetFPS = 60
        let dt = 1.0 / 60.0
        for i in 0..<100 {
            var tr = m.recordCapture(frameID: UInt64(i), at: Double(i) * dt)
            m.recordDecode(&tr, at: Double(i) * dt + 0.001)
            m.recordProcess(&tr, at: Double(i) * dt + 0.0015)
            m.recordRender(&tr, at: Double(i) * dt + 0.002)
            m.recordPresent(tr, at: Double(i) * dt + 0.003)
        }
        // 帧 100 缺失，101 到来且间隔正常（≈1 帧）→ transport drop
        let i = 101
        let t = Double(i) * dt
        var tr = m.recordCapture(frameID: UInt64(i), at: t)
        m.recordDecode(&tr, at: t + 0.001)
        m.recordProcess(&tr, at: t + 0.0015)
        m.recordRender(&tr, at: t + 0.002)
        m.recordPresent(tr, at: t + 0.003)

        let snap = m.snapshot()
        XCTAssertEqual(snap.dropsByStage[.capture], 1)
        let events = m.recentEvents()
        XCTAssertTrue(events.contains { $0.reason == .transportDrop }, "events: \(events.map(\.reason))")
    }

    /// 长间隔（采集卡没供帧）→ captureDrop。
    func testCaptureStallDetectedAsCaptureDrop() {
        let m = PerformanceMonitor()
        m.targetFPS = 60
        var tr = m.recordCapture(frameID: 0, at: 0)
        m.recordDecode(&tr, at: 0.001)
        m.recordRender(&tr, at: 0.002)
        m.recordPresent(tr, at: 0.003)
        // 下一帧晚了 200ms 且 ID 只 +1 → 采集没供帧（非传输丢帧）
        let t = 0.2
        tr = m.recordCapture(frameID: 1, at: t)
        m.recordDecode(&tr, at: t + 0.001)
        m.recordRender(&tr, at: t + 0.002)
        m.recordPresent(tr, at: t + 0.003)

        let events = m.recentEvents()
        XCTAssertTrue(events.contains { $0.reason == .possibleDroppedFrame || $0.reason == .captureDrop || $0.reason == .frameTimeSpike })
    }

    /// 渲染持续慢于处理输出 → Render Bottleneck 警告（§62）。
    func testRenderBottleneckWarning() {
        let m = PerformanceMonitor()
        m.targetFPS = 60
        let dt = 1.0 / 60.0
        // 输入完整 60FPS，但每 6 帧只在偶数帧渲染（渲染 ~30FPS）
        for i in 0..<180 {
            let t = Double(i) * dt
            var tr = m.recordCapture(frameID: UInt64(i), at: t)
            m.recordDecode(&tr, at: t + 0.001)
            m.recordProcess(&tr, at: t + 0.0015)
            if i % 2 == 0 {
                m.recordRender(&tr, at: t + 0.002)
                m.recordPresent(tr, at: t + 0.003)
            }
        }
        let snap = m.snapshot()
        XCTAssertTrue(snap.warnings.contains { $0.contains("Render") }, "warnings: \(snap.warnings)")
    }

    /// 重复帧号 → duplicate 计数。
    func testDuplicateFrameIDCounted() {
        let m = PerformanceMonitor()
        var tr = m.recordCapture(frameID: 7, at: 0)
        m.recordDecode(&tr, at: 0.001)
        m.recordRender(&tr, at: 0.002)
        m.recordPresent(tr, at: 0.003)
        tr = m.recordCapture(frameID: 7, at: 0.016)
        m.recordDecode(&tr, at: 0.017)
        m.recordRender(&tr, at: 0.018)
        m.recordPresent(tr, at: 0.019)
        XCTAssertEqual(m.snapshot().duplicateFrames, 1)
    }

    /// 输入低于目标 FPS → Capture Drop 警告。
    func testInputBelowTargetWarns() {
        let m = PerformanceMonitor()
        m.targetFPS = 60
        // 50 FPS 输入
        let dt = 1.0 / 50.0
        for i in 0..<200 {
            let t = Double(i) * dt
            var tr = m.recordCapture(frameID: UInt64(i), at: t)
            m.recordDecode(&tr, at: t + 0.001)
            m.recordProcess(&tr, at: t + 0.0015)
            m.recordRender(&tr, at: t + 0.002)
            m.recordPresent(tr, at: t + 0.003)
        }
        let snap = m.snapshot()
        XCTAssertTrue(snap.warnings.contains { $0.contains("Capture") }, "warnings: \(snap.warnings)")
    }

    /// CSV 导出：表头 + 行数正确。
    func testCSVExport() {
        let m = PerformanceMonitor()
        m.startRecording()
        let dt = 1.0 / 60.0
        for i in 0..<60 {
            let t = Double(i) * dt
            var tr = m.recordCapture(frameID: UInt64(i), at: t)
            m.recordDecode(&tr, at: t + 0.001)
            m.recordProcess(&tr, at: t + 0.0015)
            m.recordRender(&tr, at: t + 0.002)
            m.recordPresent(tr, at: t + 0.003)
            m.tickRecord(t: t)
        }
        let csv = m.exportCSV()
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.first, "timestamp,capture_fps,decode_fps,process_fps,render_fps,present_fps,dropped,duplicates,frame_time_avg_ms,frame_time_p95_ms,frame_time_p99_ms,e2e_latency_ms,render_latency_ms")
        XCTAssertEqual(lines.count, 61)   // header + 60
        m.stopRecording()
    }

    /// 端到端延迟计算。
    func testE2ELatency() {
        let m = PerformanceMonitor()
        var tr = m.recordCapture(frameID: 0, at: 1.000)
        m.recordDecode(&tr, at: 1.002)
        m.recordProcess(&tr, at: 1.003)
        m.recordRender(&tr, at: 1.005)
        m.recordPresent(tr, at: 1.007)
        let snap = m.snapshot()
        XCTAssertEqual(snap.e2eLatencyMs ?? -1, 7.0, accuracy: 0.5)
    }

    /// 帧时间统计 P50/P95/P99。
    func testFrameTimePercentiles() {
        let stats = FrameTimeStats.compute(from: [16, 16, 16, 16, 16, 16, 16, 16, 20, 40])
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats!.p50Ms, 16, accuracy: 0.01)
        XCTAssertEqual(stats!.maxMs, 40, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(stats!.p95Ms, 20)
        XCTAssertLessThan(stats!.p50Ms, stats!.p95Ms)
        XCTAssertLessThanOrEqual(stats!.p95Ms, stats!.p99Ms)
    }
}
