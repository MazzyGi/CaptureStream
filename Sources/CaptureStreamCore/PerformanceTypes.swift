import Foundation

/// 管线阶段。掉帧按阶段归因（规范 §14/§16/§62）。
public enum PipelineStage: String, Sendable, CaseIterable {
    case capture
    case decode
    case process
    case render
    case present
}

/// 掉帧/异常事件类型。
public enum DropReason: String, Sendable {
    case captureDrop        // 采集卡未按时供帧（输入序列号缺失）
    case transportDrop      // 序列号跳变但间隔正常（USB/驱动异常）
    case decodeDrop         // 解码慢于输入
    case queueOverflow      // 有界队列满，主动丢帧
    case renderDrop         // 渲染慢于处理输出
    case presentDrop        // present 慢于渲染
    case frameTimeSpike     // 帧时间超阈值
    case possibleDroppedFrame // 帧时间严重超限
}

/// 一次掉帧/异常记录。
public struct DropEvent: Sendable {
    public let stage: PipelineStage
    public let reason: DropReason
    public let at: Double          // monotonic 秒
    public let expectedFrameID: UInt64
    public let receivedFrameID: UInt64?
    public let detail: String

    public init(stage: PipelineStage, reason: DropReason, at: Double,
                expectedFrameID: UInt64, receivedFrameID: UInt64? = nil, detail: String = "") {
        self.stage = stage
        self.reason = reason
        self.at = at
        self.expectedFrameID = expectedFrameID
        self.receivedFrameID = receivedFrameID
        self.detail = detail
    }
}

/// 滚动窗口 FPS 统计（每阶段一份）。
public final class StageCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var timestamps: [Double] = []
    private var window: Double

    public init(window: Double = 1.0) {
        self.window = window
    }

    public func record(_ t: Double) {
        lock.lock(); defer { lock.unlock() }
        timestamps.append(t)
        prune(olderThan: t - window)
    }

    /// 修剪窗口外样本。保留至少 1 个。
    private func prune(olderThan cutoff: Double) {
        // 二分找第一个 >= cutoff 的位置
        var lo = 0, hi = timestamps.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if timestamps[mid] < cutoff { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0 { timestamps.removeFirst(lo) }
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return timestamps.count
    }

    /// 样本数是否足够给出可靠的 FPS（用于抑制启动期伪掉帧事件）。
    public var hasEnoughSamples: Bool {
        lock.lock(); defer { lock.unlock() }
        return timestamps.count >= 8
    }

    /// 窗口内 FPS（基于最早/最新时间戳跨度，避免计数抖动）。
    /// 样本不足 2 个时回退为计数值。
    public var fps: Double {
        lock.lock(); defer { lock.unlock() }
        guard timestamps.count >= 2 else { return Double(timestamps.count) }
        let span = timestamps.last! - timestamps.first!
        guard span > 0 else { return Double(timestamps.count) }
        return Double(timestamps.count - 1) / span
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        timestamps.removeAll()
    }
}

/// 帧间隔统计（avg/P50/P95/P99/max，规范 §61）。
public struct FrameTimeStats: Sendable, Equatable {
    public var avgMs: Double
    public var p50Ms: Double
    public var p95Ms: Double
    public var p99Ms: Double
    public var maxMs: Double

    public static func compute(from intervalsMs: [Double]) -> FrameTimeStats? {
        guard !intervalsMs.isEmpty else { return nil }
        let sorted = intervalsMs.sorted()
        func pct(_ p: Double) -> Double {
            let idx = Int((p * Double(sorted.count - 1)).rounded())
            return sorted[max(0, min(sorted.count - 1, idx))]
        }
        return FrameTimeStats(
            avgMs: intervalsMs.reduce(0, +) / Double(intervalsMs.count),
            p50Ms: pct(0.50), p95Ms: pct(0.95), p99Ms: pct(0.99),
            maxMs: sorted.last!
        )
    }
}
