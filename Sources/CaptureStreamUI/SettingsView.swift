#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import CaptureStreamCore

/// Settings 窗口（§24-§30）：分类 Tab。
public struct SettingsView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        TabView {
            CaptureSettingsTab(appState: appState).tabItem { Label("Capture", systemImage: "av.remote") }
            VideoSettingsTab(appState: appState).tabItem { Label("Video", systemImage: "film") }
            ScalingSettingsTab(appState: appState).tabItem { Label("Scaling", systemImage: "arrow.up.left.and.arrow.down.right") }
            AudioSettingsTab(appState: appState).tabItem { Label("Audio", systemImage: "speaker.wave.2") }
            DisplaySettingsTab(appState: appState).tabItem { Label("Display", systemImage: "display") }
            PerformanceSettingsTab(appState: appState).tabItem { Label("Performance", systemImage: "gauge") }
        }
        .frame(width: 520, height: 420)
        .padding()
    }
}

struct CaptureSettingsTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Picker("Auto Reconnect", selection: $appState.settings.autoReconnect) {
                Text("On").tag(true); Text("Off").tag(false)
            }
            LabeledContent("Detected Devices") {
                Text("\(appState.deviceManager.devices.count) video, \(appState.deviceManager.audioDevices.count) audio")
            }
            Button("Refresh Devices") { appState.deviceManager.refresh() }
        }
        .formStyle(.grouped)
    }
}

struct VideoSettingsTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Picker("Hardware Decode", selection: .constant(true)) {
                Text("ON").tag(true)
            }
            .disabled(true)
            LabeledContent("Decoder") { Text("AVFoundation (UVC passthrough)") }
            Picker("Latency Mode", selection: $appState.settings.latencyMode) {
                ForEach(LatencyMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Frame Pacing", selection: $appState.settings.framePacing) {
                Text("VSync").tag(FramePacingMode.vsync)
                Text("Immediate").tag(FramePacingMode.immediately)
            }
            Stepper("Frame Buffer: \(appState.settings.frameBufferCount)",
                    value: $appState.settings.frameBufferCount, in: 1...4)
        }
        .formStyle(.grouped)
    }
}

struct ScalingSettingsTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Picker("Scaling", selection: $appState.settings.scalingMode) {
                ForEach(ScalingMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Filter", selection: $appState.settings.scaleFilter) {
                ForEach(ScaleFilter.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Slider(value: $appState.settings.sharpen, in: 0...100, step: 1) {
                Text("Sharpen \(Int(appState.settings.sharpen))")
            }
            Toggle("Integer Scaling", isOn: $appState.settings.integerScaling)
            Toggle("Super Resolution (experimental)", isOn: $appState.settings.superResolution)
            Toggle("Frame Interpolation (experimental)", isOn: $appState.settings.frameInterpolation)
            if appState.settings.scalingMode == .custom {
                Slider(value: $appState.settings.customScale, in: 0.1...8, step: 0.1) {
                    Text("Custom Scale \(appState.settings.customScale, specifier: "%.1fx")")
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
            Picker("Output Device", selection: $appState.settings.audioOutputDeviceID) {
                Text("System Default").tag(String?.none)
                ForEach(appState.deviceManager.audioDevices, id: \.id) { d in
                    Text(d.name).tag(String?.some(d.id))
                }
            }
            Slider(value: $appState.settings.audioVolume, in: 0...1) {
                Text("Volume \(Int(appState.settings.audioVolume * 100))%")
            }
            Toggle("Mute", isOn: $appState.settings.audioMuted)
            Slider(value: $appState.settings.audioDelayMs, in: -1000...1000, step: 10) {
                Text("Audio Delay \(Int(appState.settings.audioDelayMs))ms")
            }
        }
        .formStyle(.grouped)
    }
}

struct DisplaySettingsTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Toggle("VSync", isOn: $appState.settings.vsync)
            Toggle("Always on Top", isOn: $appState.settings.alwaysOnTop)
            Picker("Aspect Ratio", selection: $appState.settings.aspectOverride) {
                ForEach(AspectRatioMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        }
        .formStyle(.grouped)
    }
}

struct PerformanceSettingsTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Toggle("Performance Overlay", isOn: $appState.settings.showPerformanceOverlay)
            Toggle("Advanced Metrics", isOn: $appState.settings.overlayAdvancedMetrics)
            Toggle("Frame Debug", isOn: $appState.settings.showFrameDebug)
            Slider(value: $appState.settings.spikeThresholdMs, in: 10...60, step: 1) {
                Text("Spike Threshold \(Int(appState.settings.spikeThresholdMs))ms")
            }
            Slider(value: $appState.settings.dropThresholdMs, in: 20...100, step: 1) {
                Text("Drop Threshold \(Int(appState.settings.dropThresholdMs))ms")
            }
            HStack {
                Button(appState.isRecording ? "Stop Recording" : "Start Recording") {
                    appState.toggleRecording()
                }
                Button("Export CSV") { appState.exportCSV() }
                Button("Export JSON") { appState.exportJSON() }
            }
            LabeledContent("Recording Rows") { Text("\(appState.recordingRows)") }
        }
        .formStyle(.grouped)
    }
}
#endif
