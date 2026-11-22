import SwiftUI
import AppKit

// Building blocks shared by the menu bar popover and the main window.

struct Divider1px: View {
    let theme: MmTheme

    var body: some View {
        Rectangle().fill(theme.border).frame(height: 1)
    }
}

/// Big monospaced value, small label, segmented meter.
struct MetricReadout: View {
    let theme: MmTheme
    let label: String
    let value: String
    let ratio: Double
    var valueColor: Color?
    var tint: Color?
    var valueSize: CGFloat = 15
    /// Optional extra line under the meter (kept below it so meters stay aligned across tiles).
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.system(size: valueSize, weight: .semibold, design: .monospaced))
                .foregroundStyle(valueColor ?? theme.ink)
            Text(label)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .tracking(1)
                .foregroundStyle(theme.soft)
                .lineLimit(1)
            MmLinearMeter(theme: theme, ratio: ratio, segments: 6, tint: tint)
            if let detail {
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.soft)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Thermal badge and interactive heat-source line. Renders nothing while the Mac is cool and idle.
struct InsightRow: View {
    @ObservedObject var appState: AppState
    let theme: MmTheme

    var body: some View {
        let badge = appState.thermalBadge
        let source = appState.heatSource
        if badge != nil || source != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if let badge {
                        let color = appState.thermalLevel.isThrottling ? theme.terracotta : theme.amber
                        HStack(spacing: 5) {
                            Circle().fill(color).frame(width: 6, height: 6)
                            Text(badge)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(color)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(color.opacity(0.12), in: Capsule())
                    }
                    if let source {
                        Button {
                            appState.isHeatSourceExpanded.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                (Text("\(appState.t.heatSource)  ")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.soft)
                                + Text(source.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(theme.ink)
                                + Text("  \(Int(source.cpuPercent.rounded()))%")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(theme.soft))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(appState.isHeatSourceExpanded ? "▴" : "▾")
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.soft)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }

                if appState.isHeatSourceExpanded && !appState.topProcesses.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(appState.topProcesses) { proc in
                            HStack(spacing: 6) {
                                Text(proc.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(theme.ink)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text("\(Int(proc.cpuPercent.rounded()))%")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(theme.soft)
                                if proc.isApplication {
                                    processAction(appState.t.switchToApp, color: theme.accent) {
                                        appState.activateProcess(proc)
                                    }
                                }
                                processAction(appState.t.quitProcess, color: theme.soft) {
                                    appState.terminateProcess(proc, force: false)
                                }
                                processAction(appState.t.forceQuitProcess, color: theme.terracotta) {
                                    appState.terminateProcess(proc, force: true)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.border, lineWidth: 1))
                }
            }
        }
    }

    private func processAction(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

/// The four readouts: CPU, memory pressure, CPU temperature, GPU temperature.
struct MetricRow: View {
    @ObservedObject var appState: AppState
    let theme: MmTheme
    var valueSize: CGFloat = 15
    var spacing: CGFloat = 14
    /// Window only: show system power under CPU and GPU busy % under GPU temperature.
    var showsDetails = false

    var body: some View {
        let t = appState.t
        let pressureTint = Self.pressureTint(appState.memoryPressure.level, theme: theme)
        HStack(alignment: .top, spacing: spacing) {
            MetricReadout(theme: theme, label: t.cpu, value: "\(Int(appState.cpuUsage.rounded()))%",
                          ratio: appState.cpuUsage / 100, valueSize: valueSize,
                          detail: showsDetails ? appState.power.systemWatts.map(t.systemPower) : nil)
            MetricReadout(theme: theme, label: t.pressure, value: "\(Int(appState.memoryPressure.percent.rounded()))%",
                          ratio: appState.memoryPressure.percent / 100,
                          valueColor: pressureTint, tint: pressureTint ?? theme.accent, valueSize: valueSize)
            MetricReadout(theme: theme, label: t.temp, value: Self.celsius(appState.thermal.cpuAverageCelsius),
                          ratio: Self.heat(appState.thermal.cpuAverageCelsius), valueSize: valueSize)
            MetricReadout(theme: theme, label: t.gpu, value: Self.celsius(appState.thermal.gpuCelsius),
                          ratio: Self.heat(appState.thermal.gpuCelsius), valueSize: valueSize,
                          detail: showsDetails ? appState.gpuUsage.map { t.gpuUsage(Int($0.rounded())) } : nil)
        }
    }

    /// Normal pressure uses the regular ink/accent; warning and critical get a color.
    static func pressureTint(_ level: MemoryPressureLevel, theme: MmTheme) -> Color? {
        switch level {
        case .normal: return nil
        case .warning: return theme.amber
        case .critical: return theme.terracotta
        }
    }

    static func celsius(_ value: Double) -> String {
        value > 0 ? "\(Int(value.rounded()))°" : "--"
    }

    /// Maps 30...100 °C onto 0...1 so the meter turns terracotta around 90 °C.
    static func heat(_ value: Double) -> Double {
        (value - 30) / 70
    }
}

/// Fan header + slider (or unlock button / fanless note).
struct FanControlSection: View {
    @ObservedObject var appState: AppState
    let theme: MmTheme

    var body: some View {
        let t = appState.t
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(t.fan)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink)
                Spacer()
                if appState.hasFans {
                    Text(appState.fanReadout)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(theme.soft)
                }
            }

            if !appState.hasFans {
                Text(t.noFans)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.soft)
            } else if !appState.isSMCAuthorized {
                Button(action: appState.authorize) {
                    Text(t.unlockFan)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Text(t.unlockHint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.soft)
            } else {
                fanModePicker(t: t)

                switch appState.fanMode {
                case .auto:
                    Text(t.autoRule)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.soft)
                case .cool, .chill:
                    if let rule = appState.activeCurveRule {
                        VStack(alignment: .leading, spacing: 6) {
                            MmLinearMeter(theme: theme, ratio: appState.smartTargetRatio, segments: 12)
                            Text(rule)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(theme.soft)
                        }
                        .padding(.top, 2)
                    }
                case .manual:
                    MmSlider(theme: theme, value: $appState.fanSliderValue, in: 0...100, step: 1) { editing in
                        appState.isDraggingFan = editing
                        if !editing {
                            appState.applyFanSlider(appState.fanSliderValue)
                        }
                    }
                    HStack {
                        Text(t.min)
                        Spacer()
                        Text(t.max)
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.soft)
                }
            }

            if let message = appState.statusText {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.terracotta)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fanModePicker(t: Strings) -> some View {
        HStack(spacing: 0) {
            modeSegment(t.auto, mode: .auto)
            Rectangle().fill(theme.border).frame(width: 1, height: 18)
            modeSegment(t.cool, mode: .cool)
            Rectangle().fill(theme.border).frame(width: 1, height: 18)
            modeSegment(t.chill, mode: .chill)
            Rectangle().fill(theme.border).frame(width: 1, height: 18)
            modeSegment(t.manual, mode: .manual)
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func modeSegment(_ title: String, mode: FanControlMode) -> some View {
        let selected = appState.fanMode == mode
        return Button {
            appState.setFanMode(mode)
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? theme.accent : theme.soft)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(selected ? theme.accent.opacity(0.12) : theme.surface)
        }
        .buttonStyle(.plain)
    }
}

/// Two-segment EN | 中 switch.
struct LanguageToggle: View {
    @ObservedObject var appState: AppState
    let theme: MmTheme

    var body: some View {
        HStack(spacing: 0) {
            segment("EN", .en)
            Rectangle().fill(theme.border).frame(width: 1, height: 14)
            segment("中", .zh)
        }
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func segment(_ title: String, _ language: AppLanguage) -> some View {
        let selected = appState.language == language
        return Button {
            appState.language = language
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(selected ? theme.accent : theme.soft)
                .frame(width: 26, height: 18)
                .background(selected ? theme.accent.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}

/// Three-segment menu bar density switch (Compact / Balanced / Full).
struct DensityToggle: View {
    @ObservedObject var appState: AppState
    let theme: MmTheme

    var body: some View {
        let t = appState.t
        HStack(spacing: 0) {
            segment(t.densityCompact, .compact)
            Rectangle().fill(theme.border).frame(width: 1, height: 14)
            segment(t.densityBalanced, .balanced)
            Rectangle().fill(theme.border).frame(width: 1, height: 14)
            segment(t.densityFull, .full)
        }
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .help(t.menuBarDensityHelp)
    }

    private func segment(_ title: String, _ density: MenuBarDensity) -> some View {
        let selected = appState.menuBarDensity == density
        return Button {
            appState.menuBarDensity = density
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(selected ? theme.accent : theme.soft)
                .frame(width: 22, height: 18)
                .background(selected ? theme.accent.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}

/// Launch-at-login checkbox and Quit.
struct FooterBar: View {
    @ObservedObject var appState: AppState
    let theme: MmTheme

    var body: some View {
        HStack(spacing: 8) {
            MmCheckbox(theme: theme, isChecked: appState.launchAtLogin) {
                appState.setLaunchAtLogin(!appState.launchAtLogin)
            }
            Text(appState.t.launchAtLogin)
                .font(.system(size: 12))
                .foregroundStyle(theme.soft)
            Spacer()
            Button(appState.t.quit) { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.soft)
        }
    }
}
