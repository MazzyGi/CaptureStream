#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AVFoundation
import CaptureStreamCore

/// 主窗口内容：视频视图 + 顶部工具栏 + 底部状态条。
public struct MainWindow: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !appState.isFullscreen {
                toolbar
                Divider()
            }
            ZStack(alignment: .topLeading) {
                VideoContainerView(appState: appState)
                if appState.settings.showPerformanceOverlay {
                    PerformanceOverlayView(snapshot: appState.latestSnapshot,
                                           advanced: appState.settings.overlayAdvancedMetrics)
                        .padding(8)
                }
                if appState.settings.showFrameDebug {
                    FrameDebugView(trace: appState.lastPresentedTrace)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                if let err = appState.errorMessage {
                    errorBanner(err)
                }
                if appState.sourceKind == .testPattern && appState.isRunning {
                    Text("TEST PATTERN")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(4)
                        .background(.ultraThinMaterial)
                        .cornerRadius(4)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            if !appState.isFullscreen {
                Divider()
                statusBar
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .sheet(isPresented: $appState.showSettings) {
            SettingsView(appState: appState)
        }
    }

    private var selectedDeviceInvalid: Bool {
        appState.selectedDeviceID == nil
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Device", selection: $appState.selectedDeviceID) {
                Text("None").tag(String?.none)
                ForEach(appState.deviceManager.devices, id: \.id) { d in
                    Text(d.name).tag(String?.some(d.id))
                }
                Divider()
                Text("Test Pattern (1080p60 NV12)").tag(String?.some(AppState.testPatternID))
            }
            .frame(minWidth: 220)

            Picker("Format", selection: $appState.selectedFormatLabel) {
                Text("Default").tag(String?.none)
                ForEach(appState.availableFormats, id: \.self) { f in
                    Text(f).tag(String?.some(f))
                }
            }
            .frame(minWidth: 200)

            Button {
                appState.isRunning.toggle()
            } label: {
                Text(appState.isRunning ? "Stop" : "Start")
                    .frame(minWidth: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(appState.isRunning ? .red : .accentColor)
            .disabled(selectedDeviceInvalid)

            Spacer()

            Picker("Scaling", selection: $appState.settings.scalingMode) {
                ForEach(ScalingMode.allCases, id: \.self) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .frame(minWidth: 180)

            Picker("Filter", selection: $appState.settings.scaleFilter) {
                ForEach(ScaleFilter.allCases, id: \.self) { f in
                    Text(f.rawValue.capitalized).tag(f)
                }
            }

            Button {
                appState.showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)

            Button {
                appState.isFullscreen.toggle()
            } label: {
                Image(systemName: appState.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            if let f = appState.activeFormat {
                Text("\(appState.deviceName) · \(f.label)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(appState.deviceName)
            }
            Spacer()
            if let snap = appState.latestSnapshot {
                Text(String(format: "FPS %.1f / %.1f", snap.renderFPS, snap.captureFPS))
                Text(String(format: "FrameTime %.2fms", snap.frameTime?.avgMs ?? 0))
                Text("Drop \(snap.totalDrops)")
                if let lat = snap.e2eLatencyMs {
                    Text(String(format: "Latency %.1fms", lat))
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func errorBanner(_ msg: String) -> some View {
        VStack {
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
                .padding(10)
                .background(Color.red.opacity(0.85))
                .cornerRadius(8)
                .padding(12)
            Spacer()
        }
    }
}

/// 视频容器：NSViewRepresentable 包 CAMetalLayer 宿主。
public struct VideoContainerView: NSViewRepresentable {
    @ObservedObject var appState: AppState

    public func makeNSView(context: Context) -> MetalHostView {
        let v = MetalHostView()
        v.appState = appState
        appState.attach(layer: v.metalLayer)
        return v
    }

    public func updateNSView(_ nsView: MetalHostView, context: Context) {
        nsView.appState = appState
    }
}

/// CAMetalLayer 宿主 view（layer-backed）。
public final class MetalHostView: NSView {
    public let metalLayer = CAMetalLayer()
    var appState: AppState? {
        didSet { appState?.attach(layer: metalLayer) }
    }

    public override func makeBackingLayer() -> CALayer {
        metalLayer
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = metalLayer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window, let screen = window.screen {
            let scale = screen.backingScaleFactor
            metalLayer.contentsScale = scale
            metalLayer.drawableSize = CGSize(width: frame.size.width * scale,
                                             height: frame.size.height * scale)
        }
        appState?.viewportChanged(bounds.size)
    }

    public override func layout() {
        super.layout()
        let scale = metalLayer.contentsScale > 0 ? metalLayer.contentsScale : 1
        metalLayer.drawableSize = CGSize(width: max(frame.size.width * scale, 1),
                                         height: max(frame.size.height * scale, 1))
        appState?.viewportChanged(bounds.size)
    }
}
#endif
