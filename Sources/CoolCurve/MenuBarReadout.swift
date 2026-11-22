import AppKit

/// One reading the menu bar can show. Shown in this (declaration) order, whatever order they were picked in.
public enum MenuBarItem: String, CaseIterable, Sendable {
    case cpu, memory, cpuTemp, gpuTemp, fanRPM, power, mode
}

/// Quick presets kept from the old S / M / L switch.
public enum MenuBarDensity: String, CaseIterable, Sendable {
    case compact   // 52°C
    case balanced  // CPU 23%  52°C
    case full      // CPU 23%  MEM 61%  52°C

    var items: Set<MenuBarItem> {
        switch self {
        case .compact: return [.cpuTemp]
        case .balanced: return [.cpu, .cpuTemp]
        case .full: return [.cpu, .memory, .cpuTemp]
        }
    }
}

/// The readings one menu bar string is built from; nil means "no reading".
struct MenuBarValues {
    var cpu: Int
    var memory: Int
    var cpuTemp: Int?
    var gpuTemp: Int?
    var fanRPM: Int?
    var watts: Int?
    var mode: String
}

enum MenuBarFormat {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
    /// Menu bar items wider than this tend to end up hidden behind the notch.
    static let notchFriendlyWidth: CGFloat = 170

    /// Numbers are padded with FIGURE SPACE (U+2007, exactly one digit wide in the monospaced-digit font)
    /// and a missing reading uses FIGURE DASH (U+2012), so 9 → 19 → 99 doesn't change the width.
    static func text(_ items: Set<MenuBarItem>, _ v: MenuBarValues) -> String {
        func pad(_ value: Int?, _ digits: Int) -> String {
            guard let value else { return String(repeating: "\u{2012}", count: digits) }
            let text = String(value)
            return String(repeating: "\u{2007}", count: max(0, digits - text.count)) + text
        }
        return MenuBarItem.allCases.filter(items.contains).map { item -> String in
            switch item {
            case .cpu: return "CPU \(pad(v.cpu, 2))%"
            case .memory: return "MEM \(pad(v.memory, 2))%"
            case .cpuTemp: return "\(pad(v.cpuTemp, 2))°C"
            case .gpuTemp: return "GPU \(pad(v.gpuTemp, 2))°"
            case .fanRPM: return "\(pad(v.fanRPM, 4))rpm"
            case .power: return "\(pad(v.watts, 2))W"
            case .mode: return v.mode
            }
        }.joined(separator: "  ")
    }

    /// Width of the gauge icon to the left of the text.
    static let iconWidth: CGFloat = 18

    /// Fixed status item width: the widest text these items can produce plus the icon, so neighbouring
    /// menu bar icons never shift as numbers change.
    static func statusItemWidth(_ items: Set<MenuBarItem>, modeNames: [String]) -> CGFloat {
        let widestMode = modeNames.max { width(of: $0) < width(of: $1) } ?? ""
        let widest = text(items, MenuBarValues(cpu: 100, memory: 99, cpuTemp: 99, gpuTemp: 99,
                                               fanRPM: 9999, watts: 100, mode: widestMode))
        let textWidth = items.isEmpty ? 0 : width(of: " " + widest)
        return ceil(textWidth + iconWidth + 10)
    }

    private static func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: - Icon (a template image, so it follows the light/dark menu bar)

    static let gaugeIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)
            let center = CGPoint(x: 9, y: 9)
            ctx.setLineWidth(1.6)
            for (start, end) in [(140.0, 200.0), (222.0, 282.0), (304.0, 364.0)] {
                ctx.beginPath()
                ctx.addArc(center: center, radius: 6.8, startAngle: start * .pi / 180,
                           endAngle: end * .pi / 180, clockwise: false)
                ctx.strokePath()
            }
            ctx.addEllipse(in: CGRect(x: 7, y: 7, width: 4, height: 4))
            ctx.fillPath()
            let angle = 325.0 * CGFloat.pi / 180
            ctx.setLineWidth(1.5)
            ctx.beginPath()
            ctx.move(to: center)
            ctx.addLine(to: CGPoint(x: 9 + 4.4 * cos(angle), y: 9 + 4.4 * sin(angle)))
            ctx.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "CoolCurve"
        return image
    }()
}
