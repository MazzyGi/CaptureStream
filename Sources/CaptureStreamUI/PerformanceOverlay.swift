#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import CaptureStreamCore

/// 性能悬浮层（§31）：常显核心指标，Advanced 展开全阶段。
public struct PerformanceOverlayView: View {
    public let snapshot: PerformanceMonitor.Snapshot?
    public let advanced: Bool

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let s = snapshot {
                monospacedLine("渲染 FPS", String(format: "%.2f  (%dx%d %@)",
                                                  s.renderFPS,
                                                  s.inputResolution?.width ?? 0,
                                                  s.inputResolution?.height ?? 0,
                                                  s.pixelFormat ?? "-"))
                monospacedLine("采集 FPS", String(format: "%.2f", s.captureFPS))
                monospacedLine("解码 FPS", String(format: "%.2f", s.decodeFPS))
                monospacedLine("渲染 FPS", String(format: "%.2f", s.renderFPS))
                monospacedLine("呈现 FPS", String(format: "%.2f", s.presentFPS))
                monospacedLine("丢帧", "\(s.totalDrops)")
                monospacedLine("重复帧", "\(s.duplicateFrames)")
                if let ft = s.frameTime {
                    monospacedLine("帧时间", String(format: "%.2fms  P95 %.1f  P99 %.1f", ft.avgMs, ft.p95Ms, ft.p99Ms))
                }
                if let lat = s.e2eLatencyMs {
                    monospacedLine("端到端延迟", String(format: "%.1fms", lat))
                }
                if advanced {
                    monospacedLine("处理 FPS", String(format: "%.2f", s.processFPS))
                    if let rl = s.renderLatencyMs {
                        monospacedLine("渲染→呈现", String(format: "%.2fms", rl))
                    }
                    monospacedLine("最新帧", "#\(s.lastFrameID)")
                    ForEach(s.warnings, id: \.self) { w in
                        Text(w).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                } else {
                    ForEach(s.warnings.prefix(2), id: \.self) { w in
                        Text(w).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                Text("等待信号输入…")
                    .font(.system(size: 11, design: .monospaced))
            }
        }
        .padding(8)
        .background(.ultraThinMaterial.opacity(0.85))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func monospacedLine(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).frame(width: 92, alignment: .leading)
            Text(v)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
    }
}

/// 帧调试视图（§32）：最近一帧的完整时间戳。
public struct FrameDebugView: View {
    public let trace: FrameTrace?

    public var body: some View {
        if let t = trace {
            let cap = t.capturedAt ?? 0
            VStack(alignment: .leading, spacing: 2) {
                Text("帧 #\(t.frameID)  PTS \(t.pts)µs").bold()
                line("采集", t.capturedAt, from: cap)
                line("解码", t.decodedAt, from: cap)
                line("处理", t.processedAt, from: cap)
                line("渲染", t.renderedAt, from: cap)
                line("呈现", t.presentedAt, from: cap)
                if let p = t.presentedAt {
                    Text(String(format: "合计 %.2fms", (p - cap) * 1000))
                        .bold()
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(8)
            .background(.ultraThinMaterial.opacity(0.85))
            .cornerRadius(8)
        }
    }

    private func line(_ name: String, _ t: Double?, from base: Double) -> some View {
        HStack {
            Text(name).frame(width: 56, alignment: .leading)
            if let t { Text(String(format: "%+.2fms", (t - base) * 1000)) }
            else { Text("—") }
        }
    }
}

/// 帧时间图（§17）：最近 N 帧间隔。
public struct FrameTimeGraph: View {
    public let samples: [Double]   // ms
    public let maxMs: Double

    public init(samples: [Double], maxMs: Double = 40) {
        self.samples = samples
        self.maxMs = maxMs
    }

    public var body: some View {
        Canvas { ctx, size in
            guard samples.count > 1 else { return }
            let step = size.width / CGFloat(samples.count - 1)
            var path = Path()
            for (i, s) in samples.enumerated() {
                let x = CGFloat(i) * step
                let y = size.height * (1 - CGFloat(min(s / maxMs, 1)))
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .color(.green), lineWidth: 1)
            var ref = Path()
            ref.move(to: CGPoint(x: 0, y: size.height * (1 - 16.67 / maxMs)))
            ref.addLine(to: CGPoint(x: size.width, y: size.height * (1 - 16.67 / maxMs)))
            ctx.stroke(ref, with: .color(.gray.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }
}
#endif
