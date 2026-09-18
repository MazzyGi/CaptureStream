#if canImport(AVFoundation) && canImport(AVAudioEngine) || canImport(CoreAudio)
import AVFoundation
import Foundation
import CaptureStreamCore

/// 音频管线：采集卡 HDMI 音频（AVCaptureDevice audio）→ AVAudioEngine 播放。
/// 音频延迟（§21 A/V Sync 手动补偿）通过环形缓冲偏移实现。
public final class AudioPipeline {

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
    private var srcFormat: AVAudioFormat?
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
    }

    public func updateConfig(_ new: Config) {
        ringLock.lock()
        config = new
        ringLock.unlock()
        applyVolume()
    }

    // MARK: - 采集（AVCaptureSession 由外部视频会话共享或独立创建）

    /// 附加到已有 AVCaptureSession 的音频输出（推荐：与视频同卡）。
    public func attach(to session: AVCaptureSession, deviceID: String?) {
        detach()
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
        audioOutput = out
        captureSession = session
    }

    public func detach() {
        if let session = captureSession, let out = audioOutput {
            session.beginConfiguration()
            if let input = session.inputs.first(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true }) {
                session.removeInput(input)
            }
            session.removeOutput(out)
            session.commitConfiguration()
        }
        captureSession = nil
        audioOutput = nil
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
        guard let node = playerNode, let format = srcFormat ?? engine.mainMixerNode.outputFormat(forBus: 0) else { return }
        if let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) {
            buf.frameLength = 1024
            node.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
        }
        _ = node
        // 实际使用中由 tap 驱动，见 installTap
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
}

extension AudioPipeline: AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let pcm = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,
                bufferListSizeNeededOut: nil)?.bufferList else { return }
        lastAudioCapturedAt = CFAbsoluteTimeGetCurrent()

        // 提取交织样本 → 环形缓冲
        var samples: [Float] = []
        var list = UnsafeMutableAudioBufferListPointer(pcm)
        let chans = list.count
        if chans == 2 {
            // 双 buffer（非交织）→ 交织
            let a = list[0], b = list[1]
            guard let pa = a.mData?.assumingMemoryBound(to: Float.self),
                  let pb = b.mData?.assumingMemoryBound(to: Float.self) else { return }
            let n = Int(a.mDataByteSize) / MemoryLayout<Float>.size
            samples.reserveCapacity(n * 2)
            for i in 0..<n {
                samples.append(pa[i]); samples.append(pb[i])
            }
        } else if chans == 1, let p = list[0].mData?.assumingMemoryBound(to: Float.self) {
            let n = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
            samples = Array(UnsafeBufferPointer(start: p, count: n))
        }
        _ = list
        configureRing(sampleRate: 48000, channels: 2)
        pushSamples(samples)

        // 播放：拉取延迟后的数据装进 playerNode
        if let node = playerNode, !samples.isEmpty {
            let delayed = pullSamples(samples.count)
            let fmt = srcFormat ?? AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            srcFormat = fmt
            if let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(delayed.count / 2)) {
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
