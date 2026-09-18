#if canImport(AVFoundation) && canImport(AppKit)
import AVFoundation
import CoreMedia
import Foundation
import CaptureStreamCore

/// 采集设备发现：枚举 UVC/HDMI 采集卡（AVFoundation video input devices）。
/// macOS 14+ 用 AVCaptureDevice.DiscoverySession；同时监听热插拔（§40）。
public final class CaptureDeviceManager: ObservableObject {

    @Published public private(set) var devices: [CaptureDeviceDescriptor] = []
    @Published public private(set) var audioDevices: [CaptureDeviceDescriptor] = []

    public var onDeviceChanged: (() -> Void)?

    private var observation: NSObjectProtocol?
    private let deviceTypes: [AVCaptureDevice.DeviceType] = {
        if #available(macOS 14.0, *) {
            return [.external, .builtInWideAngleCamera, .continuityCamera]
        } else {
            return [.externalUnknown]
        }
    }()

    /// 音频设备枚举类型（macOS 14 需用 .external 显式包含采集卡音频实体）。
    private let audioDeviceTypes: [AVCaptureDevice.DeviceType] = {
        if #available(macOS 14.0, *) {
            return [.external, .builtInMicrophone]
        } else {
            return [.externalUnknown]
        }
    }()

    public init() {
        refresh()
        observation = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDisconnected),
            name: .AVCaptureDeviceWasDisconnected, object: nil)
    }

    deinit {
        if let o = observation { NotificationCenter.default.removeObserver(o) }
        NotificationCenter.default.removeObserver(self, name: .AVCaptureDeviceWasDisconnected, object: nil)
    }

    @objc private func handleDisconnected() { refresh() }

    /// 重新枚举设备与格式能力。
    public func refresh() {
        var result: [CaptureDeviceDescriptor] = []
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified)
        for d in session.devices {
            // 过滤明显非采集卡的内置 FaceTime 摄像头？——不过滤，由用户选择；
            // 但标注 manufacturer 便于识别。
            result.append(descriptor(from: d))
        }
        devices = result.sorted { $0.name < $1.name }

        var audio: [CaptureDeviceDescriptor] = []
        for d in AVCaptureDevice.DiscoverySession(
            deviceTypes: audioDeviceTypes, mediaType: .audio, position: .unspecified).devices {
            var desc = CaptureDeviceDescriptor(id: d.uniqueID, name: d.localizedName,
                                               manufacturer: d.manufacturer, isUVC: false,
                                               formats: [], hasAudio: true)
            desc.formats = audioFormats(from: d)
            audio.append(desc)
        }
        audioDevices = audio.sorted { $0.name < $1.name }
        onDeviceChanged?()
    }

    /// 从 AVCaptureDevice 提取所有 (w, h, fps, pixelFormat) 组合，去重排序。
    private func descriptor(from d: AVCaptureDevice) -> CaptureDeviceDescriptor {
        var formats: [CaptureFormatDescriptor] = []
        var seen = Set<String>()
        for f in d.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard dims.width > 0, dims.height > 0 else { continue }
            let codec = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            let pf = Self.pixelFormatName(codec)
            for range in f.videoSupportedFrameRateRanges {
                guard range.maxFrameRate > 0 else { continue }
                // 连续区间（min~max）只取 max 挡位；UVC 常见离散挡 30/60 由此覆盖。
                // NTSC 59.94 显示为 60（内部应用时用设备报告的原 duration）。
                let fps = Int(range.maxFrameRate.rounded())
                guard fps > 0 else { continue }
                let key = "\(dims.width)x\(dims.height)x\(fps)x\(pf)"
                if seen.insert(key).inserted {
                    formats.append(CaptureFormatDescriptor(width: Int(dims.width),
                                                            height: Int(dims.height),
                                                            fps: fps, pixelFormat: pf))
                }
            }
        }
        // 同分辨率下保留每个像素格式；排序：面积降序、fps 降序
        formats.sort { a, b in
            if a.width * a.height != b.width * b.height { return a.width * a.height > b.width * b.height }
            return a.fps > b.fps
        }
        return CaptureDeviceDescriptor(
            id: d.uniqueID, name: d.localizedName,
            manufacturer: d.manufacturer,
            isUVC: d.modelID.contains("UVC") || d.deviceType == .externalUnknown,
            formats: formats,
            hasAudio: d.hasMediaType(.audio))
    }

    private func audioFormats(from d: AVCaptureDevice) -> [CaptureFormatDescriptor] {
        d.formats.compactMap { f in
            guard let desc = CMAudioFormatDescriptionGetStreamBasicDescription(f.formatDescription) else { return nil }
            let sr = Int(desc.pointee.mSampleRate)
            let ch = Int(desc.pointee.mChannelsPerFrame)
            return CaptureFormatDescriptor(width: sr, height: ch, fps: 0,
                                           pixelFormat: ch == 2 ? "Stereo \(sr)Hz" : "\(ch)ch \(sr)Hz")
        }
    }

    /// 四字符码 → 可读像素格式名。
    public static func pixelFormatName(_ codec: FourCharCode) -> String {
        switch codec {
        case kCVPixelFormatType_32BGRA: return "BGRA"
        case kCVPixelFormatType_32ARGB: return "ARGB"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return "NV12"
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return "NV12F"
        case kCVPixelFormatType_420YpCbCr8Planar: return "YUV420"
        case kCVPixelFormatType_422YpCbCr8: return "YUV422"
        case kCVPixelFormatType_422YpCbCr8_yuvs: return "YUV422s"
        case kCVPixelFormatType_444YpCbCr8: return "YUV444"
        case kCVPixelFormatType_OneComponent8: return "Luma8"
        default:
            // UVC 压缩格式四字符码（MJPG/H264/H265/YUY2/2VUY 等）
            let b = codec.bigEndianBytes
            let s = String(bytes: [b.0, b.1, b.2, b.3], encoding: .ascii) ?? ""
            switch s {
            case "MJPG", "JPEG": return "MJPEG"
            case "H264", "AVC1": return "H264"
            case "H265", "HEVC": return "H265"
            case "YUY2", "YUYV": return "YUY2"
            case "2VUY", "UYVY": return "UYVY"
            default: return s.isEmpty ? "0x\(String(codec, radix: 16))" : s
            }
        }
    }

    public func device(withID id: String) -> CaptureDeviceDescriptor? {
        devices.first { $0.id == id } ?? audioDevices.first { $0.id == id }
    }
}

extension FourCharCode {
    /// 四字符码按大端拆成 4 字节。
    var bigEndianBytes: (UInt8, UInt8, UInt8, UInt8) {
        let b = UInt32(self)
        return (UInt8((b >> 24) & 0xFF), UInt8((b >> 16) & 0xFF),
                UInt8((b >> 8) & 0xFF), UInt8(b & 0xFF))
    }
}
#endif
