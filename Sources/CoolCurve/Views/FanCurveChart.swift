import SwiftUI

/// The active mode as one smooth hairline: CPU temperature → fan speed, turning terracotta where the
/// shared hot clamp takes over, with a dot at the fan's real position right now.
struct FanCurveChart: View {
    let theme: MmTheme
    let mode: FanControlMode
    /// Manual mode's level, 0...1.
    let manualRatio: Double
    /// Current CPU °C and fan ratio, if known.
    let current: (celsius: Double, ratio: Double)?
    let strings: Strings
    var height: CGFloat = 64

    static let minCelsius = 40.0
    static let maxCelsius = 95.0
    private static let step = 2.5

    var body: some View {
        Canvas { context, size in
            let top: CGFloat = 6, bottom: CGFloat = 13, inset: CGFloat = 2
            let plot = CGRect(x: inset, y: top, width: size.width - inset * 2, height: size.height - top - bottom)
            func x(_ celsius: Double) -> CGFloat {
                let clamped = min(max(celsius, Self.minCelsius), Self.maxCelsius)
                return plot.minX + CGFloat((clamped - Self.minCelsius) / (Self.maxCelsius - Self.minCelsius)) * plot.width
            }
            func y(_ ratio: Double) -> CGFloat { plot.maxY - CGFloat(min(max(ratio, 0), 1)) * plot.height }
            let hot = ChassisFanController.hotCelsius
            let label = Font.system(size: 9, design: .monospaced)

            // Baseline, the 85° tick, and three temperature labels
            var baseline = Path()
            baseline.move(to: CGPoint(x: plot.minX, y: plot.maxY))
            baseline.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
            context.stroke(baseline, with: .color(theme.border), lineWidth: 0.75)
            var tick = Path()
            tick.move(to: CGPoint(x: x(hot), y: plot.maxY - 3))
            tick.addLine(to: CGPoint(x: x(hot), y: plot.maxY + 2))
            context.stroke(tick, with: .color(theme.terracotta), lineWidth: 1)
            let labelY = size.height - 1
            context.draw(Text("\(Int(Self.minCelsius))°").font(label).foregroundColor(theme.soft),
                         at: CGPoint(x: plot.minX, y: labelY), anchor: .bottomLeading)
            context.draw(Text("\(Int(hot))°").font(label).foregroundColor(theme.soft),
                         at: CGPoint(x: x(hot), y: labelY), anchor: .bottom)
            context.draw(Text("\(Int(Self.maxCelsius))°").font(label).foregroundColor(theme.soft),
                         at: CGPoint(x: plot.maxX, y: labelY), anchor: .bottomTrailing)

            let stroke = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            if let profile = ChassisFanProfile.forMode(mode) {
                var points: [CGPoint] = []
                var celsius = Self.minCelsius
                while celsius <= Self.maxCelsius + 0.001 {
                    points.append(CGPoint(x: x(celsius), y: y(profile.previewRatio(atCPU: celsius))))
                    celsius += Self.step
                }
                let split = Int(((hot - Self.minCelsius) / Self.step).rounded())
                context.stroke(Self.smoothPath(points, from: 0, to: split), with: .color(theme.accent), style: stroke)
                context.stroke(Self.smoothPath(points, from: split, to: points.count - 1), with: .color(theme.terracotta), style: stroke)
            } else if mode == .manual {
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y(manualRatio)))
                line.addLine(to: CGPoint(x: plot.maxX, y: y(manualRatio)))
                context.stroke(line, with: .color(theme.accent), style: stroke)
            } else {
                context.draw(Text(strings.curveMacOS).font(label).foregroundColor(theme.soft),
                             at: CGPoint(x: plot.midX, y: plot.midY), anchor: .center)
            }

            // Where the fan really is: a soft halo around a solid dot
            guard let now = current else { return }
            let center = CGPoint(x: x(now.celsius), y: y(now.ratio))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)),
                         with: .color(theme.accent.opacity(0.15)))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 2.8, y: center.y - 2.8, width: 5.6, height: 5.6)),
                         with: .color(theme.accent))
        }
        .frame(height: height)
    }

    /// Catmull-Rom through `points[from...to]` as cubic Béziers, using the neighbours outside the range
    /// for tangents so two adjacent spans meet without a kink.
    private static func smoothPath(_ points: [CGPoint], from: Int, to: Int) -> Path {
        var path = Path()
        guard to > from, points.indices.contains(from), points.indices.contains(to) else { return path }
        path.move(to: points[from])
        for i in from..<to {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}
