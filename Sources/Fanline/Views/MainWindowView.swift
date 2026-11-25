import SwiftUI

/// Design A: readouts, a 5-minute temperature + fan history, and the fan slider in one fixed-size window.
public struct MainWindowView: View {
    @ObservedObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    public init(appState: AppState) {
        self.appState = appState
    }

    private var theme: MmTheme { MmTheme(isDark: colorScheme == .dark) }

    public var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider1px(theme: theme)
            VStack(alignment: .leading, spacing: 12) {
                MetricRow(appState: appState, theme: theme, valueSize: 20, spacing: 18, showsDetails: true)
                InsightRow(appState: appState, theme: theme)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Divider1px(theme: theme)
            historySection
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            Divider1px(theme: theme)
            FanControlSection(appState: appState, theme: theme)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            Divider1px(theme: theme)
            MenuBarSettingsSection(appState: appState, theme: theme)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            Divider1px(theme: theme)
            FooterBar(appState: appState, theme: theme)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
        .frame(width: 440)
        .background(theme.bg)
    }

    /// The window uses a transparent, full-size title bar; leave room for the traffic lights on the left.
    private var titleBar: some View {
        HStack(spacing: 10) {
            Spacer()
            LanguageToggle(appState: appState, theme: theme)
            Button {
                appState.isWindowPinned.toggle()
            } label: {
                Image(systemName: appState.isWindowPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(appState.isWindowPinned ? theme.accent : theme.soft)
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.plain)
            .help(appState.t.pinWindow)
        }
        .padding(.leading, 80)
        .padding(.trailing, 14)
        .frame(height: 38)
    }

    private var historySection: some View {
        let t = appState.t
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(t.last5Minutes)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink)
                Spacer()
                legend(color: theme.terracotta, label: t.temperature)
                if appState.hasFans {
                    legend(color: theme.accent, label: t.fan)
                }
                if appState.thermalHistory.contains(where: \.isThrottling) {
                    legend(color: theme.terracotta.opacity(0.25), label: t.throttled)
                }
            }

            HistoryChart(
                temps: appState.tempHistory,
                fans: appState.fanHistory,
                thermal: appState.thermalHistory,
                fanMax: appState.maxFanRPM,
                capacity: AppState.historyCapacity,
                theme: theme
            )
            .frame(height: 96)

            HStack {
                Text(t.fiveMinutesAgo)
                Spacer()
                Text(t.now)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(theme.soft)
        }
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 10, height: 3)
            Text(label)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.soft)
        }
        .padding(.leading, 8)
    }
}

/// Temperature as a line (30–100 °C scale) over fan RPM as a filled area (0–max RPM scale),
/// with throttled periods shaded behind. The x-axis is fixed to `capacity` samples so the
/// timeline doesn't stretch while history fills up.
struct HistoryChart: View {
    let temps: [Double]
    let fans: [Double]
    let thermal: [ThermalLevel]
    let fanMax: Double
    let capacity: Int
    let theme: MmTheme

    var body: some View {
        Canvas { context, size in
            let slots = max(capacity - 1, 1)
            func x(_ index: Int, count: Int) -> CGFloat {
                size.width * CGFloat(capacity - count + index) / CGFloat(slots)
            }

            // Throttled periods (thermal state serious or critical) as background bands.
            let slotWidth = size.width / CGFloat(slots)
            for (index, level) in thermal.enumerated() where level.isThrottling {
                let rect = CGRect(x: x(index, count: thermal.count) - slotWidth / 2, y: 0,
                                  width: slotWidth + 0.5, height: size.height)
                context.fill(Path(rect), with: .color(theme.terracotta.opacity(level == .critical ? 0.2 : 0.12)))
            }

            // Guide lines at 50 °C and 80 °C.
            for celsius in [50.0, 80.0] {
                let y = size.height * (1 - CGFloat((celsius - 30) / 70))
                var guide = Path()
                guide.move(to: CGPoint(x: 0, y: y))
                guide.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(guide, with: .color(theme.border.opacity(0.7)),
                               style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                context.draw(
                    Text("\(Int(celsius))°").font(.system(size: 9, design: .monospaced)).foregroundColor(theme.soft),
                    at: CGPoint(x: size.width - 2, y: y - 7), anchor: .trailing
                )
            }

            // Fan RPM area.
            if fanMax > 0, fans.count > 1 {
                var area = Path()
                area.move(to: CGPoint(x: x(0, count: fans.count), y: size.height))
                for (index, rpm) in fans.enumerated() {
                    let y = size.height * (1 - CGFloat(min(max(rpm / fanMax, 0), 1)))
                    area.addLine(to: CGPoint(x: x(index, count: fans.count), y: y))
                }
                area.addLine(to: CGPoint(x: x(fans.count - 1, count: fans.count), y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(theme.accent.opacity(0.22)))
            }

            // Temperature line; skip samples with no reading.
            var line = Path()
            var penDown = false
            for (index, celsius) in temps.enumerated() {
                guard celsius > 0 else {
                    penDown = false
                    continue
                }
                let point = CGPoint(
                    x: x(index, count: temps.count),
                    y: size.height * (1 - CGFloat(min(max((celsius - 30) / 70, 0), 1)))
                )
                if penDown {
                    line.addLine(to: point)
                } else {
                    line.move(to: point)
                    penDown = true
                }
            }
            context.stroke(line, with: .color(theme.terracotta), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))

            // Baseline.
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(baseline, with: .color(theme.border), lineWidth: 1)
        }
    }
}
