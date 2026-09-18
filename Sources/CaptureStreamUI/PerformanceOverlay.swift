#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import CaptureStreamCore

/// 性能 Overlay（§31）：常显核心指标，Advanced 展开全阶段。
public struct PerformanceOverlayView: View {
    public let snapshot: PerformanceMonitor.Snapshot?
    public let advanced: Bool

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let s = snapshot {
                monospacedLine("FPS", String(format: "%.2f  (%dx%d %@)", s.renderFPS,
                                              s.inputResolution?.width ?? 0,
                                              s.inputResolution?.height ?? 0,
                                              s.pixelFormat ?? "-"))
                monospacedLine("Capture", String(format: "%.2f", s.captureFPS))
                monospacedLine("Decode", String(format: "%.2f", s.decodeFPS))
                monospacedLine("Render", String(format: "%.2f", s.renderFPS))
                monospacedLine("Present", String(format: "%.2f", s.presentFPS))
                monospacedLine("Dropped", "\(s.totalDrops)")
                monospacedLine("Dup", "\(s.duplicateFrames)")
                if let ft = s.frameTime {
                    monospacedLine("FrameTime", String(format: "%.2fms  p95 %.1f  p99 %.1f", ft.avgMs, ft.p95Ms, ft.p99Ms))
                }
                if let lat = s.e2eLatencyMs {
                    monospacedLine("Latency", String(format: "%.1fms", lat))
                }
                if advanced {
                    monospacedLine("Process", String(format: "%.2f", s.processFPS))
                    if let rl = s.renderLatencyMs {
                        monospacedLine("Render→Present", String(format: "%.2fms", rl))
                    }
                    monospacedLine("LastFrame", "#\(s.lastFrameID)")
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
                Text("waiting for frames…")
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
            Text(k).frame(width: 100, alignment: .leading)
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
                Text("Frame #\(t.frameID)  PTS \(t.pts)µs").bold()
                line("Capture", t.capturedAt, from: cap)
                line("Decode", t.decodedAt, from: cap)
                line("Process", t.processedAt, from: cap)
                line("Render", t.renderedAt, from: cap)
                line("Present", t.presentedAt, from: cap)
                if let p = t.presentedAt {
                    Text(String(format: "Total %.2fms", (p - cap) * 1000))
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
            Text(name).frame(width: 70, alignment: .leading)
            if let t { Text(String(format: "%+.2fms", (t - base) * 1000)) }
            else { Text("—") }
        }
    }
}

/// 帧时间图（§17）：Sparkline 最近 N 帧间隔。
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
            // 16.67ms 参考线
            var ref = Path()
            ref.move(to: CGPoint(x: 0, y: size.height * (1 - 16.67 / maxMs)))
            ref.addLine(to: CGPoint(x: size.width, y: size.height * (1 - 16.67 / maxMs)))
            ctx.stroke(ref, with: .color(.gray.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }
}
#endif
