import Foundation
import CaptureStreamCore

/// 帧率协商的纯逻辑（与 VideoCaptureSession.apply 同源规则）：
/// 候选 = 设备 range 端点原值；按目标 fps 就近选取；匹配谓词用端点语义。
/// 抽出为纯函数以便在无设备环境（Linux CI/本地）穷举测试。
public enum FrameRateNegotiator {

    /// 一个帧率区间的两端点（秒）。
    public struct Range {
        public var minDurationSec: Double   // 最快（fps 上限）
        public var maxDurationSec: Double   // 最慢（fps 下限）
        public init(minDurationSec: Double, maxDurationSec: Double) {
            self.minDurationSec = minDurationSec
            self.maxDurationSec = maxDurationSec
        }
    }

    /// 就近端点选择。返回 nil 表示无有效端点。
    public static func nearestEndpointDuration(targetFPS: Double, ranges: [Range]) -> Double? {
        var candidates: [Double] = []
        for r in ranges {
            if r.minDurationSec > 0 { candidates.append(r.minDurationSec) }
            if r.maxDurationSec > 0 { candidates.append(r.maxDurationSec) }
        }
        guard !candidates.isEmpty else { return nil }
        let target = 1.0 / max(targetFPS, 1)
        return candidates.min(by: { abs($0 - target) < abs($1 - target) })
    }

    /// 端点语义的格式匹配（目标 fps 是否有端点接近）。
    public static func fpsMatches(targetFPS: Int, ranges: [Range]) -> Bool {
        for r in ranges {
            for ep in [r.minDurationSec, r.maxDurationSec] where ep > 0 {
                if abs(1.0 / ep - Double(targetFPS)) < 0.75 { return true }
            }
        }
        return false
    }

    /// 结果 fps（选中的端点倒数）。
    public static func resultingFPS(durationSec: Double) -> Double {
        durationSec > 0 ? 1.0 / durationSec : 0
    }
}
