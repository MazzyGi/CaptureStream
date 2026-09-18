import XCTest
@testable import CaptureStreamCore

final class ScalingTests: XCTestCase {

    func testPixelPerfectIsOneToOne() {
        // 视口 == 输入：1 input pixel = 1 display pixel，原点对齐
        let r = ScalingMath.destinationRect(input: Size(width: 1920, height: 1080),
                                            viewport: Size(width: 1920, height: 1080),
                                            mode: .pixelPerfect)
        XCTAssertEqual(r.x, 0); XCTAssertEqual(r.y, 0)
        XCTAssertEqual(r.w, 1920); XCTAssertEqual(r.h, 1080)
    }

    func testPixelPerfectLargerViewportCentersWithoutScaling() {
        // 视口更大：仍保持 1920×1080 居中，绝不放大
        let r = ScalingMath.destinationRect(input: Size(width: 1920, height: 1080),
                                            viewport: Size(width: 2560, height: 1440),
                                            mode: .pixelPerfect)
        XCTAssertEqual(r.w, 1920); XCTAssertEqual(r.h, 1080)
        XCTAssertEqual(r.x, 320); XCTAssertEqual(r.y, 180)
    }

    func testIntegerScaling2x() {
        // 1920×1080 → 2x → 3840×2160（规范 §9 示例）
        let r = ScalingMath.destinationRect(input: Size(width: 1920, height: 1080),
                                            viewport: Size(width: 3840, height: 2160),
                                            mode: .integer)
        XCTAssertEqual(r.w, 3840); XCTAssertEqual(r.h, 2160)
    }

    func testIntegerScalingNonIntegerViewportKeepsAspectRatio() {
        // 2500×1400 只能 1x，保持 1920×1080 + 黑边，不非整数拉伸
        let r = ScalingMath.destinationRect(input: Size(width: 1920, height: 1080),
                                            viewport: Size(width: 2500, height: 1400),
                                            mode: .integer)
        XCTAssertEqual(r.w, 1920); XCTAssertEqual(r.h, 1080)
    }

    func testIntegerScalingCappedAt4x() {
        // 超大视口上限 4x
        let r = ScalingMath.destinationRect(input: Size(width: 320, height: 240),
                                            viewport: Size(width: 3840, height: 2160),
                                            mode: .integer)
        // sy = floor(2160/240)=9 → cap 4；sx = 12 → cap 4 → min=4
        XCTAssertEqual(r.w, 1280); XCTAssertEqual(r.h, 960)
    }

    func testFitMaintainsAspect() {
        // 16:9 输入放入 16:10 视口（等宽更高）：宽度受限，上下留边
        let r = ScalingMath.destinationRect(input: Size(width: 1920, height: 1080),
                                            viewport: Size(width: 1920, height: 1200),
                                            mode: .fit)
        XCTAssertEqual(r.w, 1920, accuracy: 0.001)
        XCTAssertEqual(r.w / r.h, 1920.0 / 1080.0, accuracy: 0.001)
        XCTAssertEqual(r.h, 1080, accuracy: 0.001)
        XCTAssertEqual(r.y, 60, accuracy: 0.001)   // (1200-1080)/2
    }

    func testStretchFillsEverything() {
        let r = ScalingMath.destinationRect(input: Size(width: 1920, height: 1080),
                                            viewport: Size(width: 1000, height: 1000),
                                            mode: .stretch)
        XCTAssertEqual(r.w, 1000); XCTAssertEqual(r.h, 1000)
    }

    func testFillCrops() {
        // 16:9 填满 4:3 视口 → 宽度超出裁切
        let r = ScalingMath.destinationRect(input: Size(width: 1920, height: 1080),
                                            viewport: Size(width: 1024, height: 768),
                                            mode: .fill)
        XCTAssertEqual(r.h, 768, accuracy: 0.001)
        XCTAssertGreaterThan(r.w, 1024)
    }

    func testAspectRatioOverride() {
        // 4:3 强制宽高比在 16:9 视口 fit：左右黑边，高度撑满
        let r = ScalingMath.destinationRect(input: Size(width: 1920, height: 1080),
                                            viewport: Size(width: 1920, height: 1080),
                                            mode: .fit, aspect: .ratio4x3)
        XCTAssertEqual(r.w / r.h, 4.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(r.h, 1080, accuracy: 0.001)
        XCTAssertEqual(r.w, 1440, accuracy: 0.001)   // 1080 * 4/3
        XCTAssertEqual(r.x, 240, accuracy: 0.001)    // (1920-1440)/2
    }

    func testFilterSelection() {
        XCTAssertEqual(ScalingMath.filter(for: .pixelPerfect, requested: .lanczos), .nearest)
        XCTAssertEqual(ScalingMath.filter(for: .integer, requested: .bicubic), .nearest)
        XCTAssertEqual(ScalingMath.filter(for: .fit, requested: .lanczos), .lanczos)
    }

    func testInvalidInputGivesZeroRect() {
        let r = ScalingMath.destinationRect(input: Size(width: 0, height: 0),
                                            viewport: Size(width: 100, height: 100),
                                            mode: .fit)
        XCTAssertEqual(r.w, 0); XCTAssertEqual(r.h, 0)
    }
}
