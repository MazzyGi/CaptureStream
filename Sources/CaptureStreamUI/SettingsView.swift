#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import CaptureStreamCore

/// 设置窗口（§24-§30）：分类 Tab。
public struct SettingsView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置")
                    .font(.headline)
                Spacer()
                Button {
                    appState.showSettings = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(.horizontal)
            .padding(.top, 8)
            Divider().padding(.top, 6)
            TabView {
                CaptureSettingsTab(appState: appState).tabItem { Label("采集", systemImage: "av.remote") }
                VideoSettingsTab(appState: appState).tabItem { Label("视频", systemImage: "film") }
                ScalingSettingsTab(appState: appState).tabItem { Label("缩放", systemImage: "arrow.up.left.and.arrow.down.right") }
                AudioSettingsTab(appState: appState).tabItem { Label("音频", systemImage: "speaker.wave.2") }
                DisplaySettingsTab(appState: appState).tabItem { Label("显示", systemImage: "display") }
                PerformanceSettingsTab(appState: appState).tabItem { Label("性能", systemImage: "gauge") }
                DiagnosticsTab(appState: appState).tabItem { Label("诊断", systemImage: "waveform.path.ecg.rectangle") }
            }
            .padding(.top, 4)
        }
        .frame(width: 560, height: 480)
    }
}

/// 诊断页：管线帧计数 + 运行日志（定位 FPS=0 帧卡在哪级）。
struct DiagnosticsTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            LabeledContent("采集回调帧") { Text("\(appState.pipelineCounts.callback)") }
            LabeledContent("渲染帧") { Text("\(appState.pipelineCounts.rendered)") }
            LabeledContent("呈现帧") { Text("\(appState.pipelineCounts.presented)") }
            LabeledContent("队列深度") { Text(appState.pendingFramesLabel) }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(appState.pipelineLog.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("⚠") ? .orange : .secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)
            HStack {
                Button("清空日志") { appState.pipelineLog.removeAll() }
                Button("复制全部") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(appState.pipelineLog.joined(separator: "\n"), forType: .string)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct CaptureSettingsTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Picker("自动重连", selection: $appState.settings.autoReconnect) {
                Text("开启").tag(true); Text("关闭").tag(false)
            }
            LabeledContent("已检测设备") {
                Text("视频 \(appState.deviceManager.devices.count) 个 · 音频 \(appState.deviceManager.audioDevices.count) 个")
            }
            Button("刷新设备列表") { appState.deviceManager.refresh() }
            LabeledContent("版本") { Text(AppState.appVersion) }
        }
        .formStyle(.grouped)
    }
}

struct VideoSettingsTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            LabeledContent("硬件解码") { Text("直通（UVC 未压缩流）") }
            LabeledContent("解码器") { Text("AVFoundation (UVC passthrough)") }
            Picker("延迟模式", selection: $appState.settings.latencyMode) {
                ForEach(LatencyMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("帧调度", selection: $appState.settings.framePacing) {
                Text("垂直同步 (VSync)").tag(FramePacingMode.vsync)
                Text("立即呈现 (最低延迟)").tag(FramePacingMode.immediately)
            }
            Stepper("缓冲帧数：\(appState.settings.frameBufferCount)",
                    value: $appState.settings.frameBufferCount, in: 1...4)
        }
        .formStyle(.grouped)
    }
}

struct ScalingSettingsTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Picker("缩放模式", selection: $appState.settings.scalingMode) {
                ForEach(ScalingMode.allCases, id: \.self) { m in Text(m.displayName).tag(m) }
            }
            Picker("滤波算法", selection: $appState.settings.scaleFilter) {
                ForEach(ScaleFilter.allCases, id: \.self) { f in Text(f.displayName).tag(f) }
            }
            Slider(value: $appState.settings.sharpen, in: 0...100, step: 1) {
                Text("锐化 \(Int(appState.settings.sharpen))")
            }
            Toggle("整数倍缩放", isOn: $appState.settings.integerScaling)
            Divider()
            Toggle("超分辨率 MetalFX（实验性）", isOn: $appState.settings.superResolution)
            LabeledContent("MetalFX 状态") { Text(appState.metalFXStatus) }
            Toggle("插帧（实验性·线性混合）", isOn: $appState.settings.frameInterpolation)
            LabeledContent("插帧统计") { Text(appState.interpolationLabel) }
            if appState.settings.scalingMode == .custom {
                Slider(value: $appState.settings.customScale, in: 0.1...8, step: 0.1) {
                    Text("自定义倍率 \(appState.settings.customScale, specifier: "%.1fx")")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AudioSettingsTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("输入") {
                Picker("音频输入源", selection: $appState.settings.audioInputDeviceID) {
                    Text("自动（按视频设备匹配）").tag(String?.none)
                    ForEach(appState.deviceManager.audioDevices, id: \.id) { d in
                        Text(d.name).tag(String?.some(d.id))
                    }
                }
                LabeledContent("可用输入") {
                    Text(appState.deviceManager.audioDevices.isEmpty
                         ? "未检测到（需在系统授权麦克风）"
                         : "\(appState.deviceManager.audioDevices.count) 个设备")
                }
                Button("刷新设备列表") { appState.deviceManager.refresh() }
                Slider(value: $appState.settings.audioInputVolume, in: 0...1, step: 0.05) {
                    Text("输入增益 \(Int(appState.settings.audioInputVolume * 100))%")
                }
            }
            Section("输出") {
                Picker("输出设备", selection: $appState.settings.audioOutputDeviceID) {
                    Text("系统默认").tag(String?.none)
                    ForEach(appState.deviceManager.audioDevices, id: \.id) { d in
                        Text(d.name).tag(String?.some(d.id))
                    }
                }
                Slider(value: $appState.settings.audioVolume, in: 0...1) {
                    Text("音量 \(Int(appState.settings.audioVolume * 100))%")
                }
                Toggle("静音", isOn: $appState.settings.audioMuted)
                Slider(value: $appState.settings.audioDelayMs, in: -1000...1000, step: 10) {
                    Text("音频延迟补偿 \(Int(appState.settings.audioDelayMs))ms")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct DisplaySettingsTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Toggle("垂直同步", isOn: $appState.settings.vsync)
            Toggle("窗口置顶", isOn: $appState.settings.alwaysOnTop)
            Picker("宽高比", selection: $appState.settings.aspectOverride) {
                ForEach(AspectRatioMode.allCases, id: \.self) { a in Text(a.displayName).tag(a) }
            }
        }
        .formStyle(.grouped)
    }
}

struct PerformanceSettingsTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Toggle("性能悬浮层", isOn: $appState.settings.showPerformanceOverlay)
            Toggle("高级指标", isOn: $appState.settings.overlayAdvancedMetrics)
            Toggle("帧调试信息", isOn: $appState.settings.showFrameDebug)
            Slider(value: $appState.settings.spikeThresholdMs, in: 10...60, step: 1) {
                Text("帧尖峰阈值 \(Int(appState.settings.spikeThresholdMs))ms")
            }
            Slider(value: $appState.settings.dropThresholdMs, in: 20...100, step: 1) {
                Text("丢帧判定阈值 \(Int(appState.settings.dropThresholdMs))ms")
            }
            HStack {
                Button(appState.isRecording ? "停止记录" : "开始记录") {
                    appState.toggleRecording()
                }
                Button("导出 CSV…") { appState.exportCSV() }
                Button("导出 JSON…") { appState.exportJSON() }
            }
            LabeledContent("已记录行数") { Text("\(appState.recordingRows)") }
        }
        .formStyle(.grouped)
    }
}
#endif
