import XCTest
@testable import CaptureStreamCore

/// 帧率协商穷举测试：复现用户设备的典型形状，验证 60fps 不再被协商成 25。
final class FrameRateNegotiatorTests: XCTestCase {

    // 形状 A：UVC 常见——单连续区间 [fps 1..60]（端点 1fps 与 60fps）
    // 目标 60 → 选 60 端点（非区间中部 25）
    func testContinuousRangeSelects60() {
        let ranges = [FrameRateNegotiator.Range(minDurationSec: 1.0 / 60.0,   // 最快 60fps
                                                maxDurationSec: 1.0)]          // 最慢 1fps
        let d = FrameRateNegotiator.nearestEndpointDuration(targetFPS: 60, ranges: ranges)
        XCTAssertNotNil(d)
        XCTAssertEqual(FrameRateNegotiator.resultingFPS(durationSec: d!), 60, accuracy: 0.6)
        // 目标 30 在同一区间内但不是端点 → 就近端点应为 60（1/60 比 1/1 近）
        let d30 = FrameRateNegotiator.nearestEndpointDuration(targetFPS: 30, ranges: ranges)
        XCTAssertEqual(FrameRateNegotiator.resultingFPS(durationSec: d30!), 60, accuracy: 0.6)
    }

    // 形状 B：离散挡位 30/60（UVC 声明多个 range，端点恰为挡位）
    func testDiscreteTiers30And60() {
        let ranges = [
            FrameRateNegotiator.Range(minDurationSec: 1.0 / 30.0, maxDurationSec: 1.0 / 25.0),
            FrameRateNegotiator.Range(minDurationSec: 1.0 / 60.0, maxDurationSec: 1.0 / 50.0),
        ]
        XCTAssertEqual(FrameRateNegotiator.resultingFPS(
            durationSec: FrameRateNegotiator.nearestEndpointDuration(targetFPS: 60, ranges: ranges)!), 60, accuracy: 0.6)
        XCTAssertEqual(FrameRateNegotiator.resultingFPS(
            durationSec: FrameRateNegotiator.nearestEndpointDuration(targetFPS: 30, ranges: ranges)!), 30, accuracy: 0.6)
        // 目标 50 → 就近端点 50（恰有端点）
        XCTAssertEqual(FrameRateNegotiator.resultingFPS(
            durationSec: FrameRateNegotiator.nearestEndpointDuration(targetFPS: 50, ranges: ranges)!), 50, accuracy: 0.6)
    }

    // 形状 C：用户实测形状——设备只有 [25..30]（60 不可用时选最近可用挡，不选 1fps）
    func testOnlyLowTierDevice() {
        let ranges = [FrameRateNegotiator.Range(minDurationSec: 1.0 / 30.0, maxDurationSec: 1.0 / 25.0)]
        let d = FrameRateNegotiator.nearestEndpointDuration(targetFPS: 60, ranges: ranges)
        // 60 不存在 → 最近端点是 30（不是区间中部的 25，更不是 1）
        XCTAssertEqual(FrameRateNegotiator.resultingFPS(durationSec: d!), 30, accuracy: 0.6)
    }

    // 形状 D：NTSC 端点 1001/60000（59.94）
    func testNTSCEndpoint() {
        let ntsc = 1001.0 / 60000.0
        let ranges = [FrameRateNegotiator.Range(minDurationSec: ntsc, maxDurationSec: 1.0 / 25.0)]
        let d = FrameRateNegotiator.nearestEndpointDuration(targetFPS: 60, ranges: ranges)
        XCTAssertEqual(FrameRateNegotiator.resultingFPS(durationSec: d!), 59.94, accuracy: 0.1)
        // 匹配谓词：60 应匹配 59.94 端点（<0.75 容差）
        XCTAssertTrue(FrameRateNegotiator.fpsMatches(targetFPS: 60, ranges: ranges))
    }

    // 匹配谓词：端点里没有目标挡 → false（UI 不应列出该挡）
    func testFpsMatchNegative() {
        let ranges = [FrameRateNegotiator.Range(minDurationSec: 1.0 / 30.0, maxDurationSec: 1.0 / 25.0)]
        XCTAssertFalse(FrameRateNegotiator.fpsMatches(targetFPS: 60, ranges: ranges))
        XCTAssertTrue(FrameRateNegotiator.fpsMatches(targetFPS: 30, ranges: ranges))
        XCTAssertTrue(FrameRateNegotiator.fpsMatches(targetFPS: 25, ranges: ranges))
    }

    // 空端点保护
    func testEmptyRanges() {
        XCTAssertNil(FrameRateNegotiator.nearestEndpointDuration(targetFPS: 60, ranges: []))
        XCTAssertFalse(FrameRateNegotiator.fpsMatches(targetFPS: 60, ranges: []))
    }

    // 关键回归：用户的场景——选 60，设备 1080p 有 [25..60] 连续区间（含 60 端点）
    // 旧实现把 max duration（25fps 端点）当 maxFrameRate → 显示 25。
    // 新实现就近选取必须命中 1/60。
    func testRegression60NotConfusedWith25() {
        let ranges = [FrameRateNegotiator.Range(minDurationSec: 1.0 / 60.0,  // ← 60fps 端点在此
                                                maxDurationSec: 1.0 / 25.0)] // 25fps 是"最慢"端点
        let d = FrameRateNegotiator.nearestEndpointDuration(targetFPS: 60, ranges: ranges)
        XCTAssertEqual(FrameRateNegotiator.resultingFPS(durationSec: d!), 60, accuracy: 0.6,
                       "选 60 必须命中 1/60 端点，而不是 25fps 的最慢端点")
    }
}
