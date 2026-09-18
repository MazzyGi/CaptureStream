#if canImport(MetalFX)
import Foundation
import Metal
import MetalFX
import CoreVideo
import CaptureStreamCore

/// MetalFX 空间超分封装（规范 §11 探索项）。
/// - 运行时才检查 MTLFXSpatialScalerAvailability（CI 无法验证 GPU）；
/// - 不可用时 scaledMode 返回 false，UI 显示"不可用"而非伪造。
public final class MetalFXUpscaler {

    public struct Support {
        public var available: Bool
        public var reason: String
    }

    private var scaler: MTLFXSpatialScaler?
    private let device: MTLDevice
    private let queue: MTLCommandQueue

    public init?(device: MTLDevice, queue: MTLCommandQueue) {
        self.device = device
        self.queue = queue
    }

    /// 当前配置下 MetalFX 是否可用。
    /// 真实能力只能在创建 scaler 时判定（Apple 不提供独立的格式探测 API），
    /// 这里返回框架级状态，具体输入输出由 makeScaler 的返回值决定。
    public static func support() -> Support {
        return Support(available: true, reason: "框架已链接，实际能力在创建时判定")
    }

    /// 建立或复用 scaler。仅使用文档确定存在的属性：
    /// inputWidth/inputHeight/outputWidth/outputWidth/colorTextureFormat/outputTextureFormat/
    /// inputContentWidth/inputContentHeight/colorProcessingMode（macOS 14+）/fsrVersion（macOS 15+）。
    public func makeScaler(inputWidth: Int, inputHeight: Int,
                           outputWidth: Int, outputHeight: Int,
                           colorFormat: MTLPixelFormat) -> MTLFXSpatialScaler? {
        if let s = scaler,
           s.inputWidth == inputWidth, s.inputHeight == inputHeight,
           s.outputWidth == outputWidth, s.outputHeight == outputHeight {
            return s
        }
        let desc = MTLFXSpatialScalerDescriptor()
        desc.inputWidth = inputWidth
        desc.inputHeight = inputHeight
        desc.outputWidth = outputWidth
        desc.outputHeight = outputHeight
        desc.colorTextureFormat = colorFormat
        desc.outputTextureFormat = colorFormat
        if #available(macOS 14.0, *) {
            desc.colorProcessingMode = .perceptual
        }
        guard let s = desc.makeSpatialScaler(device: device) else {
            NSLog("[CaptureStream] MetalFX scaler creation failed (%dx%d → %dx%d)",
                  inputWidth, inputHeight, outputWidth, outputHeight)
            return nil
        }
        scaler = s
        return s
    }

    /// 处理一帧（input → output 纹理）。
    /// 真实 API（SDK 头文件确认）：纹理通过 colorTexture/outputTexture 属性设置，
    /// encode 只有 commandBuffer 参数（apinotes: encodeToCommandBuffer: → encode(commandBuffer:)）。
    public func process(input: MTLTexture, output: MTLTexture,
                        colorFormat: MTLPixelFormat,
                        on commandBuffer: MTLCommandBuffer) -> Bool {
        guard let s = makeScaler(inputWidth: input.width, inputHeight: input.height,
                                 outputWidth: output.width, outputHeight: output.height,
                                 colorFormat: colorFormat) else { return false }
        s.colorTexture = input
        s.outputTexture = output
        s.encode(commandBuffer: commandBuffer)
        return true
    }
}
#else
import Foundation
import CaptureStreamCore

/// 非 macOS / 无 MetalFX 框架平台的占位（Linux CI 编译占位）。
public final class MetalFXUpscaler {
    public struct Support {
        public var available: Bool
        public var reason: String
    }
    public init?(device: Any, queue: Any) { return nil }
    public static func support() -> Support { Support(available: false, reason: "本构建不含 MetalFX") }
}
#endif
