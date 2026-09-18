import Foundation

/// 缩放模式（规范 §7/§27）。
public enum ScalingMode: String, Sendable, CaseIterable, Codable {
    case fit               // 保持宽高比适配窗口
    case fill              // 填满窗口（裁切）
    case stretch           // 拉伸（变形）
    case pixelPerfect      // 1:1，中心对齐
    case integer           // 整数倍缩放
    case custom            // 用户自定义缩放系数

    public var displayName: String {
        switch self {
        case .fit: return "适应窗口 (Fit)"
        case .fill: return "填满裁切 (Fill)"
        case .stretch: return "拉伸 (Stretch)"
        case .pixelPerfect: return "点对点 1:1"
        case .integer: return "整数倍缩放"
        case .custom: return "自定义"
        }
    }
}

/// 纹理采样/滤波算法（规范 §8）。
public enum ScaleFilter: String, Sendable, CaseIterable, Codable {
    case nearest
    case bilinear
    case bicubic
    case lanczos
}

/// 宽高比模式（规范 §29）。
public enum AspectRatioMode: String, Sendable, CaseIterable, Codable {
    case original, ratio16x9, ratio16x10, ratio4x3, custom

    public var displayName: String {
        switch self {
        case .original: return "原始比例"
        case .ratio16x9: return "16:9"
        case .ratio16x10: return "16:10"
        case .ratio4x3: return "4:3"
        case .custom: return "自定义"
        }
    }

    public var aspect: Double? {
        switch self {
        case .original: return nil
        case .ratio16x9: return 16.0 / 9.0
        case .ratio16x10: return 16.0 / 10.0
        case .ratio4x3: return 4.0 / 3.0
        case .custom: return nil
        }
    }
}

/// 目标矩形（输出坐标系，points 已含 1:1 语义：pixelPerfect 时输出必须等于输入尺寸）。
public struct DestinationRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
}

/// 纯函数：输入尺寸 → 目标显示区域内的绘制矩形。
/// 这是 UI 布局与 Metal 渲染共用的唯一真源，保证 Pixel Perfect / Integer Scaling 的数学正确（规范 §7/§9）。
public enum ScalingMath {

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(v, lo), hi) }

    public static func destinationRect(input: Size, viewport: Size,
                                       mode: ScalingMode, aspect: AspectRatioMode = .original,
                                       customScale: Double = 1.0) -> DestinationRect {
        guard input.width > 0, input.height > 0, viewport.width > 0, viewport.height > 0 else {
            return DestinationRect(x: 0, y: 0, w: 0, h: 0)
        }
        let inW = Double(input.width), inH = Double(input.height)
        let vpW = Double(viewport.width), vpH = Double(viewport.height)
        let inputAspect = inW / inH
        let effectiveAspect = aspect.aspect ?? inputAspect

        func centered(_ w: Double, _ h: Double) -> DestinationRect {
            DestinationRect(x: (vpW - w) / 2, y: (vpH - h) / 2, w: w, h: h)
        }

        switch mode {
        case .stretch:
            return DestinationRect(x: 0, y: 0, w: vpW, h: vpH)

        case .fill:
            // 按有效宽高比放大至覆盖视口，超出部分裁切（渲染时用 scissor/采样越界钳制）
            let s = Swift.max(vpW / (effectiveAspect), vpH)
            return centered(s * effectiveAspect, s)

        case .fit:
            // 输入先裁切/适配到有效宽高比，再等比缩放至视口内
            // effectiveAspect 决定目标矩形宽高；尺寸取 min(vw/ea, vh)
            let s = Swift.min(vpW / effectiveAspect, vpH)
            return centered(s * effectiveAspect, s)

        case .pixelPerfect:
            // 1:1 像素映射：目标尺寸 = 输入尺寸，居中（视口小于输入时裁切边缘）
            return centered(inW, inH)

        case .integer:
            // 最大整数倍缩放，不足整倍部分留黑边（§9）
            let sx = floor(vpW / inW)
            let sy = floor(vpH / inH)
            var scale = Swift.max(1, Swift.min(sx, sy))
            scale = clamp(Double(Int(scale)), 1, 4)   // 1x~4x
            return centered(inW * scale, inH * scale)

        case .custom:
            let s = clamp(customScale, 0.1, 8.0)
            return centered(inW * s, inH * s)
        }
    }

    /// 各缩放模式应使用的采样滤波器。
    public static func filter(for mode: ScalingMode, requested: ScaleFilter) -> ScaleFilter {
        switch mode {
        case .pixelPerfect, .integer: return .nearest
        default: return requested
        }
    }
}
