import AppKit
import SwiftUI

/// Developer tool behind `Fanline --snapshot <dir> [secondsOfHistory]`: renders the popover and the main
/// window to PNG (English/Chinese × light/dark, 2×) from live readings, and the four mode curves to SVG,
/// for the README. Runs with `AppState.isSnapshotMode`, so it never touches the fans or saved preferences.
@MainActor
enum SnapshotRenderer {
    static func run(outputDirectory: URL, delay: TimeInterval) {
        let state = AppState.shared
        state.showModeForSnapshot(.cool)
        // Show a typical menu bar setup rather than whatever is saved (not persisted in snapshot mode).
        state.menuBarItems = MenuBarDensity.balanced.items
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        writeModeCurves(to: outputDirectory)
        if delay > 0 {
            print("Collecting \(Int(delay))s of readings for the history chart…")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            for language in [AppLanguage.en, .zh] {
                state.language = language
                for isDark in [false, true] {
                    let suffix = "\(language.rawValue)-\(isDark ? "dark" : "light")"
                    render(PopoverSnapshot(appState: state, isDark: isDark),
                           to: outputDirectory.appendingPathComponent("popover-\(suffix).png"))
                    render(WindowSnapshot(appState: state, isDark: isDark),
                           to: outputDirectory.appendingPathComponent("window-\(suffix).png"))
                }
            }
            print("Wrote README images to \(outputDirectory.path)")
            exit(0)
        }
    }

    private static func render<V: View>(_ view: V, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = false
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            print("Couldn't render \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
    }

    // MARK: - Mode curves (SVG)

    /// One SVG per mode, drawn from the same profiles the app uses. Mid-tone colors so a single file
    /// reads on both GitHub's light and dark themes.
    private static func writeModeCurves(to directory: URL) {
        for mode in [FanControlMode.auto, .cool, .chill, .manual] {
            let svg = modeCurveSVG(mode)
            try? svg.write(to: directory.appendingPathComponent("mode-\(mode.rawValue).svg"), atomically: true, encoding: .utf8)
        }
    }

    private static func modeCurveSVG(_ mode: FanControlMode) -> String {
        let width = 160.0, height = 80.0, inset = 6.0, top = 8.0, bottom = 14.0
        let accent = "#0A93A0", hot = "#D4572A", muted = "#8B9292"
        func x(_ celsius: Double) -> Double {
            inset + (celsius - FanCurveChart.minCelsius) / (FanCurveChart.maxCelsius - FanCurveChart.minCelsius) * (width - inset * 2)
        }
        func y(_ ratio: Double) -> Double { height - bottom - min(max(ratio, 0), 1) * (height - top - bottom) }
        func f(_ v: Double) -> String { String(format: "%.1f", v) }

        var body = """
        <line x1="\(f(inset))" y1="\(f(y(0)))" x2="\(f(width - inset))" y2="\(f(y(0)))" stroke="\(muted)" stroke-opacity="0.45" stroke-width="1"/>
        <line x1="\(f(x(85)))" y1="\(f(y(0) - 3))" x2="\(f(x(85)))" y2="\(f(y(0) + 3))" stroke="\(hot)" stroke-width="1.2"/>
        """
        let stroke = "fill=\"none\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\""
        switch mode {
        case .cool, .chill:
            let profile = mode == .cool ? ChassisFanProfile.cool : ChassisFanProfile.chill
            var points: [(Double, Double)] = []
            var celsius = FanCurveChart.minCelsius
            while celsius <= FanCurveChart.maxCelsius + 0.001 {
                points.append((x(celsius), y(profile.previewRatio(atCPU: celsius))))
                celsius += 2.5
            }
            let split = Int(((ChassisFanController.hotCelsius - FanCurveChart.minCelsius) / 2.5).rounded())
            body += "\n<path d=\"\(smoothSVGPath(points, from: 0, to: split))\" stroke=\"\(accent)\" \(stroke)/>"
            body += "\n<path d=\"\(smoothSVGPath(points, from: split, to: points.count - 1))\" stroke=\"\(hot)\" \(stroke)/>"
        case .auto:
            body += "\n<path d=\"M\(f(x(40))) \(f(y(0))) L\(f(x(66))) \(f(y(0))) Q\(f(x(86))) \(f(y(0))) \(f(x(95))) \(f(y(0.95)))\" stroke=\"\(muted)\" stroke-dasharray=\"4 4\" \(stroke)/>"
        case .manual:
            body += "\n<path d=\"M\(f(x(40))) \(f(y(0.45))) L\(f(x(95))) \(f(y(0.45)))\" stroke=\"\(accent)\" \(stroke)/>"
            body += "\n<circle cx=\"\(f(x(72)))\" cy=\"\(f(y(0.45)))\" r=\"4\" fill=\"\(accent)\"/>"
        }
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(Int(width)) \(Int(height))" width="\(Int(width))" height="\(Int(height))">
        \(body)
        </svg>

        """
    }

    /// Catmull-Rom through `points[from...to]` as cubic Béziers (same smoothing as the in-app chart).
    private static func smoothSVGPath(_ points: [(Double, Double)], from: Int, to: Int) -> String {
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        var d = "M\(f(points[from].0)) \(f(points[from].1))"
        for i in from..<to {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            let c1 = (p1.0 + (p2.0 - p0.0) / 6, p1.1 + (p2.1 - p0.1) / 6)
            let c2 = (p2.0 - (p3.0 - p1.0) / 6, p2.1 - (p3.1 - p1.1) / 6)
            d += " C\(f(c1.0)) \(f(c1.1)) \(f(c2.0)) \(f(c2.1)) \(f(p2.0)) \(f(p2.1))"
        }
        return d
    }
}

/// The popover as it appears under the menu bar: rounded, with a hairline border.
private struct PopoverSnapshot: View {
    @ObservedObject var appState: AppState
    let isDark: Bool

    var body: some View {
        let theme = MmTheme(isDark: isDark)
        MenuBarPopoverView(appState: appState, onOpenWindow: {})
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            .padding(8)
            .environment(\.colorScheme, isDark ? .dark : .light)
    }
}

/// The main window with drawn traffic lights, since an offscreen render has no window chrome.
private struct WindowSnapshot: View {
    @ObservedObject var appState: AppState
    let isDark: Bool

    var body: some View {
        let theme = MmTheme(isDark: isDark)
        MainWindowView(appState: appState)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 1.00, green: 0.37, blue: 0.34))
                    Circle().fill(Color(red: 1.00, green: 0.74, blue: 0.18))
                    Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25))
                }
                .frame(width: 52, height: 12)
                .padding(.leading, 14)
                .padding(.top, 13)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            .padding(8)
            .environment(\.colorScheme, isDark ? .dark : .light)
    }
}
