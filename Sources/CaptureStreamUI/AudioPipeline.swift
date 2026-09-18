#if canImport(AVFoundation) && canImport(AVAudioEngine) || canImport(CoreAudio)
import AVFoundation
import Foundation
import CaptureStreamCore

/// 音频管线：采集卡 HDMI 音频（AVCaptureDevice audio）→ AVAudioEngine 播放。
/// 音频延迟（§21 A/V Sync 手动补偿）通过环形缓冲偏移实现。
public final class AudioPipeline: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    public struct Config {
        public var outputDeviceID: String?
        public var volume: Double
        public var muted: Bool
        public var delayMs: Double     // -1000 ~ +1000
        public init(outputDeviceID: String? = nil, volume: Double = 1.0,
                    muted: Bool = false, delayMs: Double = 0) {
            self.outputDeviceID = outputDeviceID; self.volume = volume
            self.muted = muted; self.delayMs = delayMs
        }
    }

    private let engine = AVAudioEngine()
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let captureQueue = DispatchQueue(label: "capture.audio")

    // 播放侧
    private var playerNode: AVAudioPlayerNode?
    private var mixerTapInstalled = false
    private let ringLock = NSLock()
    private var ring: [Float] = []       // 交织 L/R
    private var ringCapacity = 0
    private var ringRead = 0, ringWrite = 0

    private var config: Config
    public var monitor: PerformanceMonitor?

    /// 采集时间戳 vs 播放时间戳 → A/V 偏差估计（ms）
    public private(set) var lastAVOffsetMs: Double = 0
    private var lastAudioCapturedAt: Double = 0

    public init(config: Config) {
        self.config = config
        super.init()
    }

    public func updateConfig(_ new: Config) {
        ringLock.lock()
        config = new
        ringLock.unlock()
        applyVolume()
    }

    // MARK: - 采集（AVCaptureSession 由外部视频会话共享或独立创建）

    /// 附加到已有 AVCaptureSession 的音频输出（推荐：与视频同卡）。
    /// sessionQueue：视频会话的串行队列，session 配置必须与视频会话互斥串行。
    public func attach(to session: AVCaptureSession, sessionQueue: DispatchQueue, deviceID: String?) {
        detach(on: sessionQueue)
        sessionQueue.sync {
            guard let device = deviceID.flatMap({ AVCaptureDevice(uniqueID: $0) })
                    ?? firstAudioCaptureDevice() else { return }
            guard let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.beginConfiguration()
            session.addInput(input)
            let out = AVCaptureAudioDataOutput()
            out.setSampleBufferDelegate(self, queue: captureQueue)
            if session.canAddOutput(out) { session.addOutput(out) }
            session.commitConfiguration()
            self.audioOutput = out
            self.captureSession = session
        }
    }

    public func detach(on sessionQueue: DispatchQueue? = nil) {
        let block = { [weak self] in
            guard let self else { return }
            if let session = self.captureSession, let out = self.audioOutput {
                session.beginConfiguration()
                if let input = session.inputs.first(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true }) {
                    session.removeInput(input)
                }
                session.removeOutput(out)
                session.commitConfiguration()
            }
            self.captureSession = nil
            self.audioOutput = nil
        }
        if let sq = sessionQueue { sq.sync(execute: block) } else { block() }
    }

    private func firstAudioCaptureDevice() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.externalUnknown],
                                         mediaType: .audio, position: .unspecified).devices.first
    }

    // MARK: - 播放

    /// 启动播放引擎（主线程调用）。
    public func startPlayback() throws {
        guard playerNode == nil else { return }
        let node = AVAudioPlayerNode()
        engine.attach(node)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) else {
            throw NSError(domain: "AudioPipeline", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot create output format"])
        }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        playerNode = node
        try engine.start()
        node.play()
        scheduleSilencePrimer()
        applyVolume()
    }

    private func scheduleSilencePrimer() {
        // playerNode 由采集回调直接 scheduleBuffer 驱动；此处不预置静音 buffer
        // （预置 .loops buffer 会阻止后续 schedule 交替，改为采集数据直接排队）
    }

    public func stopPlayback() {
        playerNode?.stop()
        engine.stop()
        if let node = playerNode { engine.detach(node) }
        playerNode = nil
        mixerTapInstalled = false
    }

    private func applyVolume() {
        guard let node = playerNode else { return }
        node.volume = config.muted ? 0 : Float(config.volume)
    }

    // MARK: - 延迟环形缓冲

    private func configureRing(sampleRate: Double, channels: Int) {
        ringLock.lock(); defer { ringLock.unlock() }
        let capacityFrames = Int(sampleRate * 1.5)   // 最大 ±1s 延迟 + 余量
        let total = capacityFrames * channels
        if ringCapacity != total {
            ringCapacity = total
            ring = [Float](repeating: 0, count: total)
            ringRead = 0; ringWrite = 0
        }
    }

    private func pushSamples(_ interleaved: [Float]) {
        ringLock.lock(); defer { ringLock.unlock() }
        for s in interleaved {
            ring[ringWrite] = s
            ringWrite = (ringWrite + 1) % ringCapacity
        }
    }

    /// 读取延迟后的样本（渲染回调）。
    private func pullSamples(_ count: Int) -> [Float] {
        ringLock.lock(); defer { ringLock.unlock() }
        let delayFrames = Int(abs(config.delayMs) * 0.001 * 48000)
        var out = [Float](repeating: 0, count: count)
        if config.delayMs >= 0 {
            // 正延迟：读指针落后写指针
            var read = (ringWrite - delayFrames * 2 + ringCapacity * 8) % ringCapacity
            for i in 0..<count {
                out[i] = ring[read]
                read = (read + 1) % ringCapacity
            }
        } else {
            // 负延迟（提前）：读指针领先
            var read = (ringWrite + delayFrames * 2 + ringCapacity * 8) % ringCapacity
            for i in 0..<count {
                out[i] = ring[read]
                read = (read + 1) % ringCapacity
            }
        }
        return out
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let asbd = CMSampleBufferGetFormatDescription(sampleBuffer)
            .flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0) }) else { return }
        let sampleRate = asbd.pointee.mSampleRate
        lastAudioCapturedAt = CFAbsoluteTimeGetCurrent()

        var ablSize = 0
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &ablSize,
            bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, blockBufferOut: &block)
        guard status == noErr || ablSize > 0 else { return }
        let listStorage = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listStorage.deallocate() }
        let got = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: listStorage.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: ablSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, blockBufferOut: &block)
        guard got == noErr else { return }

        // 提取交织样本 → 环形缓冲
        let list = UnsafeMutableAudioBufferListPointer(listStorage.assumingMemoryBound(to: AudioBufferList.self))
        var samples: [Float]
        if list.count >= 2 {
            let a = list[0], b = list[1]
            guard let pa = a.mData?.assumingMemoryBound(to: Float.self),
                  let pb = b.mData?.assumingMemoryBound(to: Float.self) else { return }
            let n = min(Int(a.mDataByteSize), Int(b.mDataByteSize)) / MemoryLayout<Float>.size
            var out = [Float](); out.reserveCapacity(n * 2)
            for i in 0..<n { out.append(pa[i]); out.append(pb[i]) }
            samples = out
        } else if let first = list.first, let p = first.mData?.assumingMemoryBound(to: Float.self) {
            let n = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            samples = Array(UnsafeBufferPointer(start: p, count: n))
        } else {
            return
        }

        configureRing(sampleRate: sampleRate > 0 ? sampleRate : 48000, channels: 2)
        pushSamples(samples)

        // 播放：拉取延迟后的数据装进 playerNode
        if let node = playerNode {
            let delayed = pullSamples(samples.count)
            if let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate > 0 ? sampleRate : 48000, channels: 2),
               let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(delayed.count / 2)) {
                buf.frameLength = AVAudioFrameCount(delayed.count / 2)
                if let l = buf.floatChannelData?[0], let r = buf.floatChannelData?[1] {
                    for i in 0..<Int(buf.frameLength) {
                        l[i] = delayed[i * 2]
                        r[i] = delayed[i * 2 + 1]
                    }
                }
                node.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
            }
        }
    }
}

import CoreMedia
import CoreAudio
#endif
