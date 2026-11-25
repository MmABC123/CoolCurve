import SwiftUI

public struct MenuBarPopoverView: View {
    @ObservedObject var appState: AppState
    let onOpenWindow: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    public init(appState: AppState, onOpenWindow: @escaping () -> Void) {
        self.appState = appState
        self.onOpenWindow = onOpenWindow
    }

    private var theme: MmTheme { MmTheme(isDark: colorScheme == .dark) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MetricRow(appState: appState, theme: theme)
            InsightRow(appState: appState, theme: theme)
            Divider1px(theme: theme)
            FanControlSection(appState: appState, theme: theme)
            Divider1px(theme: theme)
            FooterBar(appState: appState, theme: theme)
            HStack(spacing: 8) {
                LanguageToggle(appState: appState, theme: theme)
                Spacer()
                Button(action: onOpenWindow) {
                    Text("↗ " + appState.t.openWindow)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(theme.bg)
    }
}
