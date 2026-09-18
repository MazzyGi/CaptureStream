import Foundation

/// 延迟模式（规范 §22）。
public enum LatencyMode: String, Sendable, CaseIterable, Codable {
    case quality, balanced, lowLatency, ultraLow

    public var displayName: String {
        switch self {
        case .quality: return "画质优先"
        case .balanced: return "均衡"
        case .lowLatency: return "低延迟"
        case .ultraLow: return "超低延迟"
        }
    }

    /// 各模式的队列容量与策略建议。
    public var recommendedQueueCapacity: Int {
        switch self {
        case .quality: return 4
        case .balanced: return 3
        case .lowLatency: return 2
        case .ultraLow: return 1
        }
    }

    public var recommendedPolicy: QueueOverflowPolicy {
        switch self {
        case .quality: return .block
        default: return .dropOldest
        }
    }
}

/// 帧率不匹配时的表现。
public enum FramePacingMode: String, Sendable, CaseIterable, Codable {
    case vsync        // 按 VSync present（默认，流畅）
    case immediately  // 有帧即 present（最低延迟，可能 tear/被 CAMetalLayer 丢）
}

/// 采集格式描述（UVC 设备能力）。
public struct CaptureFormatDescriptor: Sendable, Equatable, Codable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var pixelFormat: String   // "BGRA" / "NV12" / "YUV420" ...
    public init(width: Int, height: Int, fps: Int, pixelFormat: String) {
        self.width = width; self.height = height; self.fps = fps; self.pixelFormat = pixelFormat
    }
    public var label: String { "\(width)×\(height) @ \(fps) FPS · \(pixelFormat)" }
}

/// 滤波算法中文名（UI 用）。
public extension ScaleFilter {
    var displayName: String {
        switch self {
        case .nearest: return "邻近采样 (Nearest)"
        case .bilinear: return "双线性 (Bilinear)"
        case .bicubic: return "双三次 (Bicubic)"
        case .lanczos: return "Lanczos"
        }
    }
}

/// 采集设备描述。
public struct CaptureDeviceDescriptor: Sendable, Equatable, Codable {
    public var id: String            // uniqueID / modelID
    public var name: String
    public var manufacturer: String?
    public var isUVC: Bool
    public var formats: [CaptureFormatDescriptor]
    public var hasAudio: Bool
    public init(id: String, name: String, manufacturer: String? = nil,
                isUVC: Bool = true, formats: [CaptureFormatDescriptor] = [], hasAudio: Bool = false) {
        self.id = id; self.name = name; self.manufacturer = manufacturer
        self.isUVC = isUVC; self.formats = formats; self.hasAudio = hasAudio
    }
}

/// 视频源类型：真实设备 / 内置测试图案（CI 无设备时验证管线，规范 §46）。
public enum VideoSourceKind: String, Sendable, Codable {
    case device
    case testPattern
}

/// 全部持久化设置（规范 §57-§58）。Codable → UserDefaults / JSON 文件。
public struct AppSettings: Sendable, Codable, Equatable {
    public var lastDeviceID: String?
    public var format: CaptureFormatDescriptor?
    public var autoReconnect: Bool

    public var scalingMode: ScalingMode
    public var scaleFilter: ScaleFilter
    public var integerScaling: Bool
    public var sharpen: Double          // 0~100
    public var superResolution: Bool
    public var frameInterpolation: Bool // 实验性
    public var customScale: Double

    public var audioInputDeviceID: String?    // 采集卡音频输入（nil = 自动匹配）
    public var audioInputVolume: Double       // 输入增益 0~1（UVC 设备硬件增益）
    public var audioOutputDeviceID: String?
    public var audioVolume: Double      // 0~1
    public var audioMuted: Bool
    public var audioDelayMs: Double     // -1000~1000

    public var latencyMode: LatencyMode
    public var framePacing: FramePacingMode
    public var frameBufferCount: Int    // 1~4

    public var vsync: Bool
    public var alwaysOnTop: Bool
    public var aspectOverride: AspectRatioMode

    public var showPerformanceOverlay: Bool
    public var overlayAdvancedMetrics: Bool
    public var showFrameDebug: Bool
    public var spikeThresholdMs: Double
    public var dropThresholdMs: Double

    public init() {
        lastDeviceID = nil
        format = nil
        autoReconnect = true
        scalingMode = .fit
        scaleFilter = .bilinear
        integerScaling = false
        sharpen = 0
        superResolution = false
        frameInterpolation = false
        customScale = 1.0
        audioOutputDeviceID = nil
        audioInputDeviceID = nil
        audioInputVolume = 1.0
        audioVolume = 1.0
        audioMuted = false
        audioDelayMs = 0
        latencyMode = .lowLatency
        framePacing = .vsync
        frameBufferCount = 2
        vsync = true
        alwaysOnTop = false
        aspectOverride = .original
        showPerformanceOverlay = false
        overlayAdvancedMetrics = false
        showFrameDebug = false
        spikeThresholdMs = 25
        dropThresholdMs = 33
    }
}

/// 设置持久化：JSON 文件 + UserDefaults 兼容（§57）。
public enum SettingsStore {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CaptureStream", isDirectory: true)
    }

    public static func load() -> AppSettings {
        let url = supportDirectory.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url) else { return AppSettings() }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    public static func save(_ s: AppSettings) {
        let dir = supportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: dir.appendingPathComponent("settings.json"), options: .atomic)
        }
    }

    public static func export(_ s: AppSettings, to url: URL) throws {
        let data = try JSONEncoder().encode(s)
        try data.write(to: url, options: .atomic)
    }

    public static func importSettings(from url: URL) throws -> AppSettings {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppSettings.self, from: data)
    }
}
