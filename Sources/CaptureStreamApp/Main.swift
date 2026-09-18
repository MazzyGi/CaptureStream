#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import CaptureStreamCore
import CaptureStreamUI

@main
struct CaptureStreamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var appState = AppState()
    @StateObject private var windowModel = WindowModel()

    var body: some Scene {
        WindowGroup {
            MainWindow(appState: appState)
                .environmentObject(windowModel)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear {
                    windowModel.appState = appState
                    windowModel.bind(appState: appState)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Performance") {
                Toggle("Performance Overlay", isOn: $appState.settings.showPerformanceOverlay)
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Toggle("Frame Debug", isOn: $appState.settings.showFrameDebug)
                Button("Toggle Recording") { appState.toggleRecording() }
                Divider()
                Button("Export CSV…") { appState.exportCSV() }
                Button("Export JSON…") { appState.exportJSON() }
            }
        }
    }
}

/// 窗口级状态：全屏切换、Always on Top（跟随 appState.isFullscreen）。
@MainActor
final class WindowModel: ObservableObject {
    weak var appState: AppState?
    private var cancellable: Any?

    func bind(appState: AppState) {
        self.appState = appState
        cancellable = appState.$isFullscreen.sink { [weak self] fullscreen in
            guard let self, let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
            let isNowFullscreen = window.styleMask.contains(.fullScreen)
            if fullscreen != isNowFullscreen {
                window.toggleFullScreen(nil)
            }
        }
        applyAlwaysOnTop(appState.settings.alwaysOnTop)
    }

    func applyAlwaysOnTop(_ on: Bool) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        window.level = on ? .floating : .normal
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#endif

#if !canImport(AppKit)
// Linux/CI 占位 main（真实 App 入口在 macOS 上方分支）
@main
enum LinuxPlaceholder {
    static func main() {
        print("CaptureStream requires macOS (Metal/AppKit). Core tests run via `swift test`.")
    }
}
#endif
