#if canImport(Metal) && canImport(CoreVideo)
import CoreVideo
import QuartzCore
import Foundation
import Metal
import CaptureStreamCore

/// Metal 渲染器：CVPixelBuffer → CVMetalTextureCache（零拷贝）→ shader 缩放+色转 → drawable。
/// 所有绘制在渲染线程执行；主线程只做 UI（§10/§35）。
public final class MetalRenderer {

    public private(set) var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var renderPipelines: [ScaleFilter: MTLRenderPipelineState] = [:]
    private var blendPipeline: MTLRenderPipelineState?
    private var samplerNearest: MTLSamplerState?
    private var samplerLinear: MTLSamplerState?

    public var monitor: PerformanceMonitor?
    public var onPresented: ((FrameTrace) -> Void)?

    // CVMetalTexture 包装必须保活到该帧 command buffer 完成
    private var liveTextures: [MTLTexture] = []

    struct DestUniforms {
        var quadNDC: SIMD4<Float>
    }
    struct YUVParams {
        var fullRange: UInt32
        var planar3: UInt32
        var isRGB: UInt32
        var sharpen: Float
    }

    public enum InitError: Error { case noDevice, noLibrary(String) }
    private var lastError: String?

    public init?(preferredDevice: MTLDevice? = nil) {
        guard let dev = preferredDevice ?? MTLCreateSystemDefaultDevice() else { return nil }
        device = dev
        guard let cq = dev.makeCommandQueue() else { return nil }
        commandQueue = cq
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, dev, nil, &cache)
        textureCache = cache
        do { try buildPipelines() }
        catch {
            lastError = "\(error)"
            NSLog("[CaptureStream] MetalRenderer init failed: \(error)")
            return nil
        }
    }

    private func buildPipelines() throws {
        guard let device else { throw InitError.noDevice }
        // metallib 加载顺序：
        // 1) SPM 资源 bundle（CaptureStreamUI_CaptureStreamUI.bundle，SwiftPM 生成）
        // 2) app bundle Resources/default.metallib（手动组装 .app 时由 CI 拷贝）
        // 3) device.makeDefaultLibrary()（CLI 直接跑 SPM 产物时的回退）
        let library: MTLLibrary?
        // SPM 不自动编译 .metal（在 Linux 上验证不了 metal 工具链），
        // CI 用 xcrun metal 编译 default.metallib 放进 app Resources。
        let appMetallib = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/default.metallib")
        if FileManager.default.fileExists(atPath: appMetallib.path) {
            library = try? device.makeLibrary(URL: appMetallib)
        } else {
            // 开发模式回退：要求 SDK 里由 makeDefaultLibrary 提供（本地 swift run 场景）
            library = device.makeDefaultLibrary()
        }
        guard let library else {
            throw InitError.noLibrary("metallib not found (SPM resource bundle / app Resources / default)")
        }
        let fragmentNames: [ScaleFilter: String] = [
            .nearest: "fragmentSample",
            .bilinear: "fragmentSample",
            .bicubic: "fragmentBicubic",
            .lanczos: "fragmentLanczos",
        ]
        guard let vs = library.makeFunction(name: "blitVS") else {
            throw InitError.noLibrary("blitVS missing")
        }
        for (filter, fsName) in fragmentNames {
            guard let fs = library.makeFunction(name: fsName) else {
                throw InitError.noLibrary("\(fsName) missing")
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vs
            desc.fragmentFunction = fs
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            renderPipelines[filter] = try device.makeRenderPipelineState(descriptor: desc)
        }
        // 插帧混合管线
        if let vs2 = library.makeFunction(name: "blitVS"),
           let fs = library.makeFunction(name: "fragmentBlend") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vs2
            desc.fragmentFunction = fs
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            blendPipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }
        let nd = MTLSamplerDescriptor()
        nd.minFilter = .nearest; nd.magFilter = .nearest
        samplerNearest = device.makeSamplerState(descriptor: nd)
        let ld = MTLSamplerDescriptor()
        ld.minFilter = .linear; ld.magFilter = .linear
        samplerLinear = device.makeSamplerState(descriptor: ld)
    }

    /// 渲染一帧。调用方：渲染线程。
    /// drawableSize 为 layer.drawableSize（pixels）；destRect 为 ScalingMath 输出（points == pixels，1:1 缩放模式下相等）。
    @discardableResult
    public func render(pixelBuffer: CVPixelBuffer, trace: FrameTrace,
                       layer: CAMetalLayer, drawableSize: CGSize,
                       destRect: DestinationRect, filter: ScaleFilter,
                       sharpen: Double, vsyncEnabled: Bool) -> Bool {
        guard let device, let queue = commandQueue, let cache = textureCache else { return false }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pf = CVPixelBufferGetPixelFormatType(pixelBuffer)

        // 纹理路径按【实际像素格式】分派（不能试探创建——BGRA 用 r8Unorm 也能建出
        // 错误纹理：B 字节被当亮度 → 全屏红）
        let planarYUV2 = pf == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                         pf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let planarYUV3 = pf == kCVPixelFormatType_420YpCbCr8Planar

        if planarYUV2 {
            guard let yTex = makeTexture(cache: cache, pb: pixelBuffer, plane: 0,
                                         format: .r8Unorm, width: width, height: height),
                  let uvTex = makeTexture(cache: cache, pb: pixelBuffer, plane: 1,
                                          format: .rg8Unorm, width: (width + 1) / 2, height: (height + 1) / 2) else { return false }
            liveTextures.append(yTex); liveTextures.append(uvTex)
            return encodeDraw(srcY: yTex, srcC: uvTex, srcV: nil, isRGB: false,
                              fullRange: pf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                              planar3: false, trace: trace, layer: layer, drawableSize: drawableSize,
                              destRect: destRect, filter: filter, sharpen: sharpen, vsyncEnabled: vsyncEnabled)
        }
        if planarYUV3 {
            guard let yTex = makeTexture(cache: cache, pb: pixelBuffer, plane: 0,
                                         format: .r8Unorm, width: width, height: height),
                  let uTex = makeTexture(cache: cache, pb: pixelBuffer, plane: 1,
                                         format: .r8Unorm, width: (width + 1) / 2, height: (height + 1) / 2),
                  let vTex = makeTexture(cache: cache, pb: pixelBuffer, plane: 2,
                                         format: .r8Unorm, width: (width + 1) / 2, height: (height + 1) / 2) else { return false }
            liveTextures.append(yTex); liveTextures.append(uTex); liveTextures.append(vTex)
            return encodeDraw(srcY: yTex, srcC: uTex, srcV: vTex, isRGB: false, fullRange: false,
                              planar3: true, trace: trace, layer: layer, drawableSize: drawableSize,
                              destRect: destRect, filter: filter, sharpen: sharpen, vsyncEnabled: vsyncEnabled)
        }

        // 单平面 RGB（BGRA/ARGB）或压缩格式解压后的 RGB
        let rgbFormat: MTLPixelFormat = (pf == kCVPixelFormatType_32ARGB) ? .rgba8Unorm : .bgra8Unorm
        guard let tex = makeTexture(cache: cache, pb: pixelBuffer, plane: 0,
                                    format: rgbFormat, width: width, height: height) else { return false }
        liveTextures.append(tex)
        return encodeDraw(srcY: tex, srcC: nil, srcV: nil, isRGB: true, fullRange: false,
                          planar3: false, trace: trace, layer: layer, drawableSize: drawableSize,
                          destRect: destRect, filter: filter, sharpen: sharpen, vsyncEnabled: vsyncEnabled)
    }

    private func encodeDraw(srcY: MTLTexture, srcC: MTLTexture?, srcV: MTLTexture?,
                            isRGB: Bool, fullRange: Bool, planar3: Bool,
                            trace: FrameTrace, layer: CAMetalLayer, drawableSize: CGSize,
                            destRect: DestinationRect, filter: ScaleFilter,
                            sharpen: Double, vsyncEnabled: Bool) -> Bool {
        guard let queue = commandQueue else { return false }
        guard let drawable = layer.nextDrawable() else { return false }

        let key: ScaleFilter = renderPipelines[filter] != nil ? filter : .bilinear
        guard let pipeline = renderPipelines[key] else { return false }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        // destRect（左上原点）→ NDC（左下 -1,1）
        let vpW = max(Double(drawableSize.width), 1)
        let vpH = max(Double(drawableSize.height), 1)
        let cx = 2.0 * (destRect.x + destRect.w / 2) / vpW - 1.0
        let cy = 1.0 - 2.0 * (destRect.y + destRect.h / 2) / vpH
        let qw = 2.0 * destRect.w / vpW
        let qh = 2.0 * destRect.h / vpH
        var uniforms = DestUniforms(quadNDC: SIMD4<Float>(Float(cx), Float(cy), Float(qw), Float(qh)))

        var yuvParams = YUVParams(fullRange: fullRange ? 1 : 0, planar3: planar3 ? 1 : 0,
                                  isRGB: isRGB ? 1 : 0, sharpen: Float(sharpen / 100.0 * 2.0))

        let now = CFAbsoluteTimeGetCurrent()
        var tr = trace
        monitor?.recordRender(&tr, at: now)

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return false }

        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<DestUniforms>.stride, index: 0)
        enc.setFragmentTexture(srcY, index: 0)
        enc.setFragmentTexture(srcC, index: 1)
        enc.setFragmentTexture(srcV, index: 2)
        let sampler = (key == .nearest) ? samplerNearest : samplerLinear
        if let sampler { enc.setFragmentSamplerState(sampler, index: 0) }
        enc.setFragmentBytes(&yuvParams, length: MemoryLayout<YUVParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        // present 打点：GPU 完成后回调（§15）
        cmd.addScheduledHandler { [weak self] _ in
            self?.monitor?.recordPresent(tr, at: CFAbsoluteTimeGetCurrent())
            self?.onPresented?(tr)
        }
        if vsyncEnabled {
            cmd.present(drawable)   // CAMetalLayer 默认按 VSync
        } else {
            cmd.present(drawable, afterMinimumDuration: 0)
        }
        cmd.addCompletedHandler { [weak self] _ in
            // 帧已消费，释放纹理引用
            DispatchQueue.main.async { self?.liveTextures.removeAll() }
        }
        cmd.commit()
        return true
    }

    /// 插帧渲染：A/B 帧线性混合（实验性）。
    @discardableResult
    public func renderBlended(a: CVPixelBuffer, b: CVPixelBuffer, t: Double,
                              trace: FrameTrace, layer: CAMetalLayer, drawableSize: CGSize,
                              destRect: DestinationRect, filter: ScaleFilter,
                              sharpen: Double, vsyncEnabled: Bool) -> Bool {
        // 两帧必须同格式同尺寸（RenderLoop 已校验尺寸）
        guard CVPixelBufferGetPixelFormatType(a) == CVPixelBufferGetPixelFormatType(b) else { return false }
        guard let cache = textureCache, let queue = commandQueue else { return false }
        let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
        let pf = CVPixelBufferGetPixelFormatType(a)
        let isNV12 = pf == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                     pf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard let ta = makeTexture(cache: cache, pb: a, plane: 0, format: isNV12 ? .r8Unorm : .bgra8Unorm, width: w, height: h),
              let tb = makeTexture(cache: cache, pb: b, plane: 0, format: isNV12 ? .r8Unorm : .bgra8Unorm, width: w, height: h) else { return false }
        liveTextures.append(ta); liveTextures.append(tb)
        var chromaA: MTLTexture?; var chromaB: MTLTexture?
        if isNV12 {
            let cw = (w + 1) / 2, ch = (h + 1) / 2
            chromaA = makeTexture(cache: cache, pb: a, plane: 1, format: .rg8Unorm, width: cw, height: ch)
            chromaB = makeTexture(cache: cache, pb: b, plane: 1, format: .rg8Unorm, width: cw, height: ch)
            if let c = chromaA { liveTextures.append(c) }
            if let c = chromaB { liveTextures.append(c) }
        }
        return encodeBlendDraw(texA: ta, texB: tb, chromaA: chromaA, chromaB: chromaB,
                               isNV12: isNV12, t: Float(t), fullRange: pf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                               trace: trace, layer: layer, drawableSize: drawableSize,
                               destRect: destRect, filter: filter)
    }

    private func encodeBlendDraw(texA: MTLTexture, texB: MTLTexture,
                                 chromaA: MTLTexture?, chromaB: MTLTexture?,
                                 isNV12: Bool, t: Float, fullRange: Bool,
                                 trace: FrameTrace, layer: CAMetalLayer, drawableSize: CGSize,
                                 destRect: DestinationRect, filter: ScaleFilter) -> Bool {
        guard let pipeline = blendPipeline, let queue = commandQueue,
              let drawable = layer.nextDrawable() else { return false }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let vpW = max(Double(drawableSize.width), 1)
        let vpH = max(Double(drawableSize.height), 1)
        let cx = 2.0 * (destRect.x + destRect.w / 2) / vpW - 1.0
        let cy = 1.0 - 2.0 * (destRect.y + destRect.h / 2) / vpH
        let qw = 2.0 * destRect.w / vpW
        let qh = 2.0 * destRect.h / vpH
        var uniforms = DestUniforms(quadNDC: SIMD4<Float>(Float(cx), Float(cy), Float(qw), Float(qh)))
        var blendParams = BlendParams(fullRange: fullRange ? 1 : 0, isNV12: isNV12 ? 1 : 0, t: t)

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return false }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<DestUniforms>.stride, index: 0)
        enc.setFragmentTexture(texA, index: 0)
        enc.setFragmentTexture(texB, index: 1)
        enc.setFragmentTexture(chromaA, index: 2)
        enc.setFragmentTexture(chromaB, index: 3)
        enc.setFragmentSamplerState(samplerLinear, index: 0)
        enc.setFragmentBytes(&blendParams, length: MemoryLayout<BlendParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        return true
    }

    struct BlendParams {
        var fullRange: UInt32
        var isNV12: UInt32
        var t: Float
    }

    private func makeTexture(cache: CVMetalTextureCache, pb: CVPixelBuffer,
                             plane: Int, format: MTLPixelFormat,
                             width: Int, height: Int) -> MTLTexture? {
        var cvTex: CVMetalTexture?
        let st = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil,
                                                           format, width, height, plane, &cvTex)
        guard st == kCVReturnSuccess, let cvTex else { return nil }
        return CVMetalTextureGetTexture(cvTex)
    }

    public func purgeCache() {
        if let cache = textureCache { CVMetalTextureCacheFlush(cache, 0) }
        liveTextures.removeAll()
    }
}
#endif
