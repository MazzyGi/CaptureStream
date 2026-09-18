import Foundation

/// 单帧在管线各阶段的时间戳记录。
/// 每帧一份，用于计算阶段耗时与掉帧判定（规范 §15/§32/§60）。
public struct FrameTrace: Sendable {
    public let frameID: UInt64
    public let pts: Int64              // 设备时间基 presentation timestamp (us)
    public var capturedAt: Double?     // mach/monotonic 秒
    public var decodedAt: Double?
    public var processedAt: Double?
    public var queuedAt: Double?
    public var renderedAt: Double?
    public var presentedAt: Double?

    public init(frameID: UInt64, pts: Int64,
                capturedAt: Double? = nil, decodedAt: Double? = nil,
                processedAt: Double? = nil, queuedAt: Double? = nil,
                renderedAt: Double? = nil, presentedAt: Double? = nil) {
        self.frameID = frameID
        self.pts = pts
        self.capturedAt = capturedAt
        self.decodedAt = decodedAt
        self.processedAt = processedAt
        self.queuedAt = queuedAt
        self.renderedAt = renderedAt
        self.presentedAt = presentedAt
    }
}
