import SwiftUI

/// Main window section for what the menu bar shows: a live preview, S/M/L presets, and a toggle per reading.
struct MenuBarSettingsSection: View {
    @ObservedObject var appState: AppState
    let theme: MmTheme

    var body: some View {
        let t = appState.t
        let width = appState.menuBarWidth
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(t.menuBarSection)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink)
                Spacer()
                Text(t.menuBarWidth(Int(width)))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(width > MenuBarFormat.notchFriendlyWidth ? theme.amber : theme.soft)
            }

            preview

            if width > MenuBarFormat.notchFriendlyWidth {
                Text(t.menuBarNotchWarning)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.amber)
            }

            row(t.menuBarPresets) { DensityToggle(appState: appState, theme: theme) }
            row(t.menuBarShow) { itemGrid(t: t) }
        }
    }

    /// A strip of menu bar with the status item as it will look, next to stand-in system items.
    private var preview: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                Image(nsImage: MenuBarFormat.gaugeIcon).renderingMode(.template)
                if !appState.menuBarItems.isEmpty {
                    Text(appState.menuBarText)
                        .font(Font(MenuBarFormat.font))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.border, lineWidth: 1))

            Image(systemName: "wifi")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.soft)
            Text(Date.now, format: .dateTime.hour().minute())
                .font(Font(MenuBarFormat.font))
                .foregroundStyle(theme.soft)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.border.opacity(0.6), lineWidth: 1))
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.soft)
                .frame(width: 64, alignment: .leading)
                .padding(.top, 3)
            content()
        }
    }

    private func itemGrid(t: Strings) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(MenuBarItem.allCases, id: \.self) { item in
                let selected = appState.menuBarItems.contains(item)
                Button {
                    appState.toggleMenuBarItem(item)
                } label: {
                    Text(name(of: item, t: t))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(selected ? theme.accent : theme.soft)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background(selected ? theme.accent.opacity(0.12) : theme.surface,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(selected ? theme.accent.opacity(0.5) : theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func name(of item: MenuBarItem, t: Strings) -> String {
        switch item {
        case .cpu: return t.menuBarItemCPU
        case .memory: return t.menuBarItemMemory
        case .cpuTemp: return t.menuBarItemCPUTemp
        case .gpuTemp: return t.menuBarItemGPUTemp
        case .fanRPM: return t.menuBarItemFan
        case .power: return t.menuBarItemPower
        case .mode: return t.menuBarItemMode
        }
    }
}
