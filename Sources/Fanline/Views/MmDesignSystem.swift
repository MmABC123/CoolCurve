import SwiftUI

// MARK: - Color tokens (maxminimalism shell.css)

public struct MmTheme: Sendable {
    public let isDark: Bool

    public init(isDark: Bool) {
        self.isDark = isDark
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    public var bg: Color { Self.hex(isDark ? 0x111211 : 0xF4F5F4) }
    public var surface: Color { Self.hex(isDark ? 0x1A1B1A : 0xFFFFFF) }
    public var surfaceMuted: Color { Self.hex(isDark ? 0x161716 : 0xEDF0F0) }
    public var border: Color { Self.hex(isDark ? 0x2E3232 : 0xC7CDCE) }
    public var ink: Color { Self.hex(isDark ? 0xE2E3E2 : 0x1D2020) }
    public var soft: Color { Self.hex(isDark ? 0x7A7E7E : 0x5C6262) }
    public var accent: Color { Self.hex(isDark ? 0x0799A5 : 0x067B85) }
    public var terracotta: Color { Self.hex(isDark ? 0xDE5723 : 0xC04A1D) }
    public var amber: Color { Self.hex(isDark ? 0xE0A33A : 0xB7791F) }
}

// MARK: - Checkbox

public struct MmCheckbox: View {
    public let theme: MmTheme
    public let isChecked: Bool
    public let action: () -> Void

    public init(theme: MmTheme, isChecked: Bool, action: @escaping () -> Void) {
        self.theme = theme
        self.isChecked = isChecked
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isChecked ? theme.accent.opacity(0.12) : theme.surfaceMuted)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(isChecked ? theme.accent : theme.border, lineWidth: 1)
                    )
                if isChecked {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(theme.accent)
                        .frame(width: 8, height: 8)
                }
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hairline slider

public struct MmSlider: View {
    public let theme: MmTheme
    @Binding public var value: Double
    public let range: ClosedRange<Double>
    public var step: Double
    /// Called with `true` while dragging and `false` once the drag ends.
    public var onEditingChanged: (Bool) -> Void

    public init(
        theme: MmTheme,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double = 1.0,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.theme = theme
        self._value = value
        self.range = range
        self.step = step
        self.onEditingChanged = onEditingChanged
    }

    private var normalized: Double {
        let span = max(range.upperBound - range.lowerBound, 0.0001)
        return min(max((value - range.lowerBound) / span, 0.0), 1.0)
    }

    public var body: some View {
        GeometryReader { geo in
            let thumbSize: CGFloat = 12
            let trackWidth = max(geo.size.width - thumbSize, 1)
            let thumbX = CGFloat(normalized) * trackWidth

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.border)
                    .frame(height: 2)
                    .padding(.horizontal, thumbSize / 2)

                Capsule()
                    .fill(theme.accent)
                    .frame(width: max(thumbX, 0), height: 2)
                    .padding(.leading, thumbSize / 2)

                Circle()
                    .fill(theme.surface)
                    .frame(width: thumbSize, height: thumbSize)
                    .overlay(Circle().strokeBorder(theme.accent, lineWidth: 2))
                    .offset(x: thumbX)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let ratio = min(max((gesture.location.x - thumbSize / 2) / trackWidth, 0.0), 1.0)
                        let raw = range.lowerBound + Double(ratio) * (range.upperBound - range.lowerBound)
                        value = min(max((raw / step).rounded() * step, range.lowerBound), range.upperBound)
                        onEditingChanged(true)
                    }
                    .onEnded { _ in onEditingChanged(false) }
            )
        }
        .frame(height: 20)
    }
}

// MARK: - Segmented meter

public struct MmLinearMeter: View {
    public let theme: MmTheme
    public let ratio: Double
    public var segments: Int
    /// Overrides the default accent / high-value terracotta fill.
    public var tint: Color?

    public init(theme: MmTheme, ratio: Double, segments: Int = 8, tint: Color? = nil) {
        self.theme = theme
        self.ratio = min(max(ratio, 0.0), 1.0)
        self.segments = max(segments, 4)
        self.tint = tint
    }

    public var body: some View {
        Canvas { context, size in
            let gap: CGFloat = 2.5
            let segWidth = max((size.width - gap * CGFloat(segments - 1)) / CGFloat(segments), 1.5)
            let activeCount = Int((ratio * Double(segments)).rounded())
            let fillColor = tint ?? (ratio >= 0.85 ? theme.terracotta : theme.accent)

            for i in 0..<segments {
                let rect = CGRect(x: CGFloat(i) * (segWidth + gap), y: 0, width: segWidth, height: size.height)
                let path = Path(roundedRect: rect, cornerRadius: 1.5)
                if i < activeCount {
                    context.fill(path, with: .color(fillColor))
                } else {
                    context.fill(path, with: .color(theme.surfaceMuted))
                    context.stroke(path, with: .color(theme.border.opacity(0.6)), lineWidth: 0.5)
                }
            }
        }
        .frame(height: 6)
    }
}
