import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case en
    case zh

    /// First launch follows the system: Chinese if the preferred language is any Chinese variant, else English.
    public static var systemDefault: AppLanguage {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? .zh : .en
    }

    public var strings: Strings {
        switch self {
        case .en: return .en
        case .zh: return .zh
        }
    }
}

/// Every user-facing string. Each language is a full instance, so a missing translation fails to compile.
public struct Strings: Sendable {
    // Metric labels
    public let cpu: String
    public let pressure: String
    public let temp: String
    public let gpu: String
    public let gpuUsage: @Sendable (Int) -> String
    public let systemPower: @Sendable (Double) -> String

    // Thermal insight
    public let thermalFair: String
    public let thermalSerious: String
    public let thermalCritical: String
    public let heatSource: String
    public let throttled: String
    public let switchToApp: String
    public let quitProcess: String
    public let forceQuitProcess: String

    // Menu bar density
    public let densityCompact: String
    public let densityBalanced: String
    public let densityFull: String
    public let menuBarDensityHelp: String
    public let menuBarSection: String
    public let menuBarPresets: String
    public let menuBarShow: String
    public let menuBarItemCPU: String
    public let menuBarItemMemory: String
    public let menuBarItemCPUTemp: String
    public let menuBarItemGPUTemp: String
    public let menuBarItemFan: String
    public let menuBarItemPower: String
    public let menuBarItemMode: String
    public let menuBarWidth: @Sendable (Int) -> String
    public let menuBarNotchWarning: String

    // Fan
    public let fan: String
    public let auto: String
    public let cool: String
    public let chill: String
    public let manual: String
    public let min: String
    public let max: String
    public let stopped: String
    public let noFans: String
    public let unlockFan: String
    public let unlockHint: String
    public let autoRule: String
    public let coolRule: String
    public let chillRule: String
    public let curveMacOS: String
    public let targetRPM: @Sendable (Int) -> String

    // Window
    public let last5Minutes: String
    public let temperature: String
    public let fiveMinutesAgo: String
    public let now: String
    public let openWindow: String
    public let pinWindow: String

    // Footer
    public let launchAtLogin: String
    public let quit: String

    // Status / errors
    public let errNotAuthorized: String
    public let errHelperMissing: String
    public let errAuthorization: @Sendable (String) -> String
    public let errCommand: @Sendable (String) -> String
    public let emergency: @Sendable (Int) -> String
    /// (current °C, resume below °C)
    public let emergencyPaused: @Sendable (Int, Int) -> String
    public let batteryAutoFan: String
    public let batteryPaused: String
    public let launchAtLoginFailed: @Sendable (String) -> String

    public static let en = Strings(
        cpu: "CPU",
        pressure: "PRESSURE",
        temp: "TEMP",
        gpu: "GPU",
        gpuUsage: { "\($0)% busy" },
        systemPower: { String(format: "%.1f W", $0) },
        thermalFair: "Running warm",
        thermalSerious: "Throttling",
        thermalCritical: "Heavy throttling",
        heatSource: "Heat source",
        throttled: "Throttled",
        switchToApp: "Show",
        quitProcess: "Quit",
        forceQuitProcess: "Force",
        densityCompact: "S",
        densityBalanced: "M",
        densityFull: "L",
        menuBarDensityHelp: "Menu bar width: Temp / CPU + Temp / Full",
        menuBarSection: "Menu bar",
        menuBarPresets: "Presets",
        menuBarShow: "Show",
        menuBarItemCPU: "CPU",
        menuBarItemMemory: "Memory",
        menuBarItemCPUTemp: "CPU temp",
        menuBarItemGPUTemp: "GPU temp",
        menuBarItemFan: "Fan speed",
        menuBarItemPower: "Power",
        menuBarItemMode: "Fan mode",
        menuBarWidth: { "≈ \($0) pt" },
        menuBarNotchWarning: "May end up hidden behind the notch — try showing less",
        fan: "Fan",
        auto: "Auto",
        cool: "Cool",
        chill: "Chill",
        manual: "Manual",
        min: "Min",
        max: "Max",
        stopped: "stopped",
        noFans: "No fans — passively cooled",
        unlockFan: "Unlock fan control",
        unlockHint: "Asks for your administrator password once",
        autoRule: "Managed automatically by macOS",
        coolRule: "Always on · slow ramps · case ≤35°C",
        chillRule: "Always ≥20% · early ramps · case ≤33°C",
        curveMacOS: "macOS decides",
        targetRPM: { "Target ≈\($0) rpm" },
        last5Minutes: "Last 5 min",
        temperature: "Temp",
        fiveMinutesAgo: "−5 min",
        now: "now",
        openWindow: "Open window",
        pinWindow: "Keep on top",
        launchAtLogin: "Launch at login",
        quit: "Quit",
        errNotAuthorized: "Unlock fan control first",
        errHelperMissing: "mm-smc-helper not found. Run scripts/build_app.sh first.",
        errAuthorization: { "Authorization didn't finish: \($0)" },
        errCommand: { "Fan command failed: \($0)" },
        emergency: { "Reached \($0)°C — handed fans back to macOS" },
        emergencyPaused: { "Reached \($0)°C — macOS has the fans until it's below \($1)°C" },
        batteryAutoFan: "Switched to battery — handed fans back to macOS",
        batteryPaused: "On battery — macOS has the fans until you plug in",
        launchAtLoginFailed: { "Couldn't change launch at login: \($0)" }
    )

    public static let zh = Strings(
        cpu: "CPU",
        pressure: "压力",
        temp: "温度",
        gpu: "GPU",
        gpuUsage: { "使用率 \($0)%" },
        systemPower: { String(format: "功耗 %.1f W", $0) },
        thermalFair: "温度偏高",
        thermalSerious: "正在降频",
        thermalCritical: "严重降频",
        heatSource: "热源",
        throttled: "降频",
        switchToApp: "切换",
        quitProcess: "退出",
        forceQuitProcess: "强退",
        densityCompact: "简",
        densityBalanced: "中",
        densityFull: "全",
        menuBarDensityHelp: "菜单栏宽度：仅温度 / CPU+温度 / 完整",
        menuBarSection: "菜单栏",
        menuBarPresets: "快速预设",
        menuBarShow: "显示内容",
        menuBarItemCPU: "CPU",
        menuBarItemMemory: "内存",
        menuBarItemCPUTemp: "CPU 温度",
        menuBarItemGPUTemp: "GPU 温度",
        menuBarItemFan: "风扇转速",
        menuBarItemPower: "功耗",
        menuBarItemMode: "风扇模式",
        menuBarWidth: { "约 \($0) pt" },
        menuBarNotchWarning: "刘海屏上可能被挡住，建议精简",
        fan: "风扇",
        auto: "原厂",
        cool: "冷静",
        chill: "清凉",
        manual: "手动",
        min: "最低",
        max: "最大",
        stopped: "停转",
        noFans: "本机无风扇，被动散热",
        unlockFan: "解锁风扇控制",
        unlockHint: "只需输入一次管理员密码",
        autoRule: "由 macOS 原生温控自动调节",
        coolRule: "常驻低速 · 缓慢调速 · 机身 ≤35°C",
        chillRule: "常驻 ≥20% · 提前提速 · 机身 ≤33°C",
        curveMacOS: "由 macOS 控制",
        targetRPM: { "目标 ≈\($0) rpm" },
        last5Minutes: "近 5 分钟",
        temperature: "温度",
        fiveMinutesAgo: "5 分钟前",
        now: "现在",
        openWindow: "打开窗口",
        pinWindow: "窗口置顶",
        launchAtLogin: "开机启动",
        quit: "退出",
        errNotAuthorized: "需要先解锁风扇控制",
        errHelperMissing: "找不到 mm-smc-helper，请先运行 scripts/build_app.sh",
        errAuthorization: { "授权未完成：\($0)" },
        errCommand: { "风扇指令失败：\($0)" },
        emergency: { "温度达到 \($0)°C，已交还系统自动温控" },
        emergencyPaused: { "温度达到 \($0)°C，暂由系统温控，降到 \($1)°C 以下后恢复" },
        batteryAutoFan: "已切换电池供电，风扇交还系统自动温控",
        batteryPaused: "电池供电中，暂由系统温控，接上电源后恢复",
        launchAtLoginFailed: { "开机启动设置失败：\($0)" }
    )
}
