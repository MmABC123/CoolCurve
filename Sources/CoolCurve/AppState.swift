import Foundation
import SwiftUI
import AppKit
import ServiceManagement
#if canImport(SMCKit)
import SMCKit
#endif

/// Menu bar width preset so notch MacBooks can keep the status item compact.
public enum MenuBarDensity: String, CaseIterable, Sendable {
    case compact   // 52°C
    case balanced  // CPU 23%  52°C
    case full      // CPU 23%  MEM 61%  52°C
}

/// Something the popover/window should tell the user. Stored as data so it re-renders in the current language.
public enum StatusMessage: Equatable, Sendable {
    case fan(FanCommandError)
    case emergency(celsius: Int)
    /// A curve mode is still selected but paused until the Mac cools down.
    case emergencyPaused(celsius: Int)
    case batteryAutoFan
    /// A curve mode is still selected but paused until power is plugged back in.
    case batteryPaused
    case launchAtLoginFailed(String)
}

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    /// In manual/curve mode, hand control back to macOS once the hottest CPU sensor stays at or above this.
    public static let emergencyCelsius: Double = 95
    /// Consecutive samples (~6s) at or above `emergencyCelsius` before acting, so one-sample peak spikes
    /// (common on M-series P-cores under load) don't kick the user out of their mode.
    public static let emergencySampleThreshold = 3
    /// A curve mode paused by the emergency takes the fans back once the hottest sensor drops below this.
    public static let emergencyResumeCelsius: Double = 85
    public static let sampleInterval: TimeInterval = 2
    /// 5 minutes of samples for the window's history chart.
    public static let historyCapacity = 150

    private enum DefaultsKey {
        static let language = "language"
        static let windowPinned = "windowPinned"
        static let menuBarDensity = "menuBarDensity"
        static let preferredCurveMode = "preferredCurveMode"
    }

    // MARK: Telemetry

    @Published public private(set) var cpuUsage: Double = 0
    @Published public private(set) var memoryPressure = MemoryPressure(percent: 0, level: .normal)
    @Published public private(set) var thermal = ThermalSnapshot(
        cpuAverageCelsius: 0, cpuPeakCelsius: 0, gpuCelsius: 0, palmRestCelsius: 0, fans: [], hasFtstKey: false
    )
    @Published public private(set) var thermalLevel: ThermalLevel = .nominal
    @Published public private(set) var gpuUsage: Double?
    @Published public private(set) var power = PowerStatus()
    @Published public private(set) var topProcesses: [HeatSource] = []
    @Published public var isHeatSourceExpanded = false
    @Published public private(set) var tempHistory: [Double] = []
    @Published public private(set) var fanHistory: [Double] = []
    @Published public private(set) var thermalHistory: [ThermalLevel] = []

    // MARK: Preferences

    @Published public var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: DefaultsKey.language) }
    }
    @Published public var isWindowPinned: Bool {
        didSet { UserDefaults.standard.set(isWindowPinned, forKey: DefaultsKey.windowPinned) }
    }
    @Published public var menuBarDensity: MenuBarDensity {
        didSet { UserDefaults.standard.set(menuBarDensity.rawValue, forKey: DefaultsKey.menuBarDensity) }
    }
    @Published public private(set) var launchAtLogin = false

    // MARK: Fan control

    @Published public private(set) var fanMode: FanControlMode = .auto {
        didSet { syncFanSlider() }
    }
    /// Manual fan level, 0...100 (% of the way from min to max RPM).
    @Published public private(set) var manualFanLevel: Double = 50 {
        didSet { syncFanSlider() }
    }
    /// Manual slider position shared by popover and window (0 = min RPM, 100 = max RPM).
    /// (Lives here because `@State` doesn't compile with the Command Line Tools toolchain.)
    @Published public var fanSliderValue: Double = 50
    @Published public var isDraggingFan = false
    /// Curve mode's current fan ratio (0 while macOS has the fans).
    @Published public private(set) var smartTargetRatio: Double = 0
    @Published public private(set) var isSMCAuthorized = false
    @Published public private(set) var status: StatusMessage?

    public let fanService = FanControlService()
    private let monitor = SystemMonitorService()
    private let processSampler = ProcessSampler()
    private var timer: Timer?
    private var wasOnAC: Bool?
    private var quietController = QuietFanController()
    private var turboController = TurboFanController()
    /// Set when a curve mode starts or resumes, so its controller restarts from the fan's current speed.
    private var curveNeedsReset = true
    private var isSmartEngaged = false
    /// Last curve speed written, and last computed, in whole percent.
    private var lastSmartWrittenPercent: Int?
    private var lastSmartOutputPercent: Int?
    private var hotSampleCount = 0
    private var isEmergencyPaused = false

    private init() {
        let defaults = UserDefaults.standard
        language = defaults.string(forKey: DefaultsKey.language).flatMap(AppLanguage.init) ?? .systemDefault
        isWindowPinned = defaults.bool(forKey: DefaultsKey.windowPinned)
        menuBarDensity = defaults.string(forKey: DefaultsKey.menuBarDensity).flatMap(MenuBarDensity.init) ?? .full
        isSMCAuthorized = fanService.isHelperAuthorized()
        launchAtLogin = SMAppService.mainApp.status == .enabled

        refresh()
        adoptCurrentFanState()
        if fanMode == .auto,
           let savedRaw = defaults.string(forKey: DefaultsKey.preferredCurveMode),
           let savedMode = FanControlMode(rawValue: savedRaw),
           savedMode.isCurveMode,
           isSMCAuthorized && hasFans {
            enableCurveMode(savedMode)
        }

        timer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Derived values

    public var t: Strings { language.strings }

    public var hasFans: Bool { !thermal.fans.isEmpty }

    public var averageFanRPM: Int {
        guard hasFans else { return 0 }
        return Int(thermal.fans.map(\.currentRPM).reduce(0, +) / Double(thermal.fans.count))
    }

    public var maxFanRPM: Double { thermal.fans.map(\.maxRPM).max() ?? 0 }

    /// The busiest process, but only while the Mac is actually working or warm — otherwise nil, and the row hides.
    public var heatSource: HeatSource? {
        guard let top = topProcesses.first, top.cpuPercent >= 30 else { return nil }
        let isBusyOrWarm = cpuUsage >= 40 || thermal.cpuAverageCelsius >= 75 || thermalLevel >= .fair
        return isBusyOrWarm ? top : nil
    }

    /// Text for the thermal badge; nil while macOS reports a nominal thermal state.
    public var thermalBadge: String? {
        switch thermalLevel {
        case .nominal: return nil
        case .fair: return t.thermalFair
        case .serious: return t.thermalSerious
        case .critical: return t.thermalCritical
        }
    }

    public var menuBarText: String {
        let temp = thermal.cpuAverageCelsius > 0 ? Int(thermal.cpuAverageCelsius.rounded()) : nil
        return Self.menuBarText(
            density: menuBarDensity,
            cpu: Int(cpuUsage.rounded()),
            mem: Int(memoryPressure.percent.rounded()),
            celsius: temp
        )
    }

    /// Widest realistic text for a given density; the status item is sized to this so it never changes width.
    public static func widestMenuBarText(for density: MenuBarDensity) -> String {
        menuBarText(density: density, cpu: 100, mem: 99, celsius: 99)
    }

    /// Numbers are padded to two digits with FIGURE SPACE (U+2007, exactly one digit wide in the
    /// monospaced-digit font), and a missing reading uses FIGURE DASH (U+2012), so 9 → 19 → 99
    /// doesn't change the text width.
    static func menuBarText(density: MenuBarDensity, cpu: Int, mem: Int, celsius: Int?) -> String {
        func pad(_ value: Int) -> String {
            let digits = String(value)
            return String(repeating: "\u{2007}", count: max(0, 2 - digits.count)) + digits
        }
        let temp = celsius.map(pad) ?? "\u{2012}\u{2012}"
        switch density {
        case .compact:
            return "\(temp)°C"
        case .balanced:
            return "CPU \(pad(cpu))%  \(temp)°C"
        case .full:
            return "CPU \(pad(cpu))%  MEM \(pad(mem))%  \(temp)°C"
        }
    }

    public var statusText: String? {
        guard let status else { return nil }
        switch status {
        case .fan(.notAuthorized): return t.errNotAuthorized
        case .fan(.helperMissing): return t.errHelperMissing
        case .fan(.authorizationFailed(let detail)): return t.errAuthorization(detail)
        case .fan(.commandFailed(let detail)): return t.errCommand(detail)
        case .emergency(let celsius): return t.emergency(celsius)
        case .emergencyPaused(let celsius): return t.emergencyPaused(celsius, Int(Self.emergencyResumeCelsius))
        case .batteryAutoFan: return t.batteryAutoFan
        case .batteryPaused: return t.batteryPaused
        case .launchAtLoginFailed(let detail): return t.launchAtLoginFailed(detail)
        }
    }

    public var fanReadout: String {
        if isDraggingFan {
            return targetRPM(forLevel: fanSliderValue).map(t.targetRPM) ?? ""
        }
        let mode: String
        switch fanMode {
        case .auto: mode = t.auto
        case .cool: mode = t.cool
        case .turbo: mode = t.turbo
        case .manual: mode = t.manual
        }
        return averageFanRPM > 0 ? "\(mode) · \(averageFanRPM) rpm" : "\(mode) · \(t.stopped)"
    }

    public var activeCurveRule: String? {
        switch fanMode {
        case .cool: return t.coolRule
        case .turbo: return t.turboRule
        case .auto, .manual: return nil
        }
    }

    /// Approximate RPM of the first fan at a given manual level.
    public func targetRPM(forLevel level: Double) -> Int? {
        guard let fan = thermal.fans.first else { return nil }
        return Int(fan.minRPM + (fan.maxRPM - fan.minRPM) * level / 100)
    }

    // MARK: - Telemetry

    public func refresh() {
        cpuUsage = monitor.sampleCPU()
        memoryPressure = monitor.sampleMemoryPressure()
        thermal = fanService.readSnapshot()
        thermalLevel = monitor.sampleThermalLevel()
        gpuUsage = monitor.sampleGPUUsage()
        power = monitor.samplePowerStatus(fallbackWatts: fanService.readSystemPowerWatts())
        topProcesses = processSampler.sampleTopProcesses(limit: 3)
        if heatSource == nil && isHeatSourceExpanded {
            isHeatSourceExpanded = false
        }

        append(thermal.cpuAverageCelsius, to: &tempHistory)
        append(Double(averageFanRPM), to: &fanHistory)
        append(thermalLevel, to: &thermalHistory)

        // Unplugging ends a manual fixed speed so it can't drain the battery. Curve modes stay selected
        // and pause themselves while on battery (see `updateCurveFan`).
        if let previousAC = wasOnAC, previousAC && !power.isOnAC && fanMode == .manual {
            restoreAuto(clearPreference: false)
            status = .batteryAutoFan
        }
        wasOnAC = power.isOnAC

        let hottest = max(thermal.cpuPeakCelsius, thermal.cpuHotspotCelsius)
        hotSampleCount = hottest >= Self.emergencyCelsius ? hotSampleCount + 1 : 0
        if hotSampleCount >= Self.emergencySampleThreshold {
            let celsius = Int(hottest.rounded())
            if fanMode == .manual {
                restoreAuto(clearPreference: false)
                status = .emergency(celsius: celsius)
            } else if fanMode.isCurveMode && !isEmergencyPaused {
                isEmergencyPaused = true
                status = .emergencyPaused(celsius: celsius)
            }
        }

        if fanMode.isCurveMode {
            updateCurveFan()
        }
    }

    private func append<Value>(_ value: Value, to history: inout [Value]) {
        history.append(value)
        if history.count > Self.historyCapacity {
            history.removeFirst(history.count - Self.historyCapacity)
        }
    }

    /// If fans were already in manual mode when we launched, reflect that in the UI.
    private func adoptCurrentFanState() {
        guard let fan = thermal.fans.first(where: \.isManualMode), fan.maxRPM > fan.minRPM else { return }
        fanMode = .manual
        manualFanLevel = min(max((fan.targetRPM - fan.minRPM) / (fan.maxRPM - fan.minRPM) * 100, 0), 100)
    }

    // MARK: - Fan Control

    private func syncFanSlider() {
        guard !isDraggingFan else { return }
        fanSliderValue = manualFanLevel
    }

    /// Manual slider value: 0 = min RPM, 100 = max RPM.
    public func applyFanSlider(_ value: Double) {
        setManualLevel(value)
    }

    public func setFanMode(_ mode: FanControlMode) {
        switch mode {
        case .auto:
            restoreAuto(clearPreference: true)
        case .cool, .turbo:
            enableCurveMode(mode)
        case .manual:
            setManualLevel(manualFanLevel)
        }
    }

    public func restoreAuto(clearPreference: Bool = true) {
        if clearPreference {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.preferredCurveMode)
        }
        fanMode = .auto
        isSmartEngaged = false
        isEmergencyPaused = false
        lastSmartWrittenPercent = nil
        smartTargetRatio = 0
        status = nil
        runFanCommand { $0.restoreAutomaticMode() }
    }

    public func enableCurveMode(_ mode: FanControlMode) {
        guard mode.isCurveMode, hasFans else { return }
        guard isSMCAuthorized else {
            status = .fan(.notAuthorized)
            return
        }
        let wasActivelyControlled = fanMode == .manual || isSmartEngaged
        UserDefaults.standard.set(mode.rawValue, forKey: DefaultsKey.preferredCurveMode)
        fanMode = mode
        curveNeedsReset = true
        isSmartEngaged = false
        lastSmartWrittenPercent = nil
        smartTargetRatio = 0
        status = nil
        updateCurveFan(forceReleaseIfCool: wasActivelyControlled)
    }

    public func setManualLevel(_ level: Double) {
        guard hasFans else { return }
        guard isSMCAuthorized else {
            status = .fan(.notAuthorized)
            return
        }
        UserDefaults.standard.removeObject(forKey: DefaultsKey.preferredCurveMode)
        fanMode = .manual
        isSmartEngaged = false
        isEmergencyPaused = false
        lastSmartWrittenPercent = nil
        smartTargetRatio = 0
        manualFanLevel = min(max(level, 0), 100)
        status = nil
        let ratio = manualFanLevel / 100
        runFanCommand { $0.setAllFansRatio(ratio) }
    }

    /// Runs one step of the active curve mode: `cool` (QuietFanController) or `turbo` (TurboFanController).
    private func updateCurveFan(forceReleaseIfCool: Bool = false) {
        guard hasFans, isSMCAuthorized, fanMode.isCurveMode else { return }

        let hottest = max(thermal.cpuPeakCelsius, thermal.cpuHotspotCelsius)
        if isEmergencyPaused && hottest < Self.emergencyResumeCelsius {
            isEmergencyPaused = false
            if case .emergencyPaused = status { status = nil }
        }

        // Too hot, or on battery: stay in this mode but let macOS drive the fans until that clears.
        if isEmergencyPaused || !power.isOnAC {
            if isEmergencyPaused {
                if case .emergencyPaused = status {} else {
                    status = .emergencyPaused(celsius: Int(hottest.rounded()))
                }
            } else {
                status = .batteryPaused
            }
            curveNeedsReset = true
            releaseCurve(force: forceReleaseIfCool)
            return
        }
        if status == .batteryPaused { status = nil }

        if curveNeedsReset {
            curveNeedsReset = false
            let start = currentFanRatio
            quietController.reset(startingAt: start)
            turboController.reset(startingAt: start)
        }

        let inputs = FanControlInputs(
            cpuAverage: thermal.cpuAverageCelsius,
            cpuPeak: thermal.cpuPeakCelsius,
            interior: thermal.internalCelsius,
            chassis: thermal.chassisCelsius,
            cpuUsage: cpuUsage,
            gpuUsage: gpuUsage ?? 0,
            isWarm: thermalLevel >= .fair,
            isThrottling: thermalLevel >= .serious,
            interval: Self.sampleInterval
        )
        let output: Double?
        switch fanMode {
        case .cool: output = quietController.step(inputs)
        case .turbo: output = turboController.step(inputs)
        case .auto, .manual: return
        }

        guard let ratio = output else {
            releaseCurve(force: forceReleaseIfCool)
            return
        }
        isSmartEngaged = true
        smartTargetRatio = ratio

        // Skip SMC writes for tiny moves while ramping, but always land on the value once it settles.
        let percent = Int((ratio * 100).rounded())
        let minStep = fanMode == .cool ? 2 : 3
        let settled = percent == lastSmartOutputPercent
        lastSmartOutputPercent = percent
        if let last = lastSmartWrittenPercent, abs(percent - last) < minStep && !(settled && percent != last) {
            return
        }
        lastSmartWrittenPercent = percent
        runFanCommand { $0.setAllFansRatio(Double(percent) / 100) }
    }

    /// Where the first fan sits between min (0) and max (1) RPM right now; 0 when stopped.
    private var currentFanRatio: Double {
        guard let fan = thermal.fans.first, fan.maxRPM > fan.minRPM else { return 0 }
        return min(max((fan.currentRPM - fan.minRPM) / (fan.maxRPM - fan.minRPM), 0), 1)
    }

    /// Hands the fans back to macOS while staying in the curve mode. Writes only if we were driving them
    /// (or `force`, when switching in from manual/another curve that may have left them pinned).
    private func releaseCurve(force: Bool) {
        let wasEngaged = isSmartEngaged
        isSmartEngaged = false
        lastSmartWrittenPercent = nil
        lastSmartOutputPercent = nil
        smartTargetRatio = 0
        if wasEngaged || force {
            runFanCommand { $0.restoreAutomaticMode() }
        }
    }

    public func authorize() {
        let result = fanService.authorizePrivilegedHelper()
        isSMCAuthorized = fanService.isHelperAuthorized()
        if case .failure(let error) = result {
            status = .fan(error)
        } else {
            status = nil
        }
    }

    /// SMC writes can block for ~1s on M3/M4 (Ftst unlock), so they run off the main thread, one at a time
    /// in issue order (see `FanControlService.submit`).
    private func runFanCommand(_ work: @escaping @Sendable (FanControlService) -> FanCommandResult) {
        fanService.submit(work) { [weak self] result in
            // nil: a newer command superseded this one before it ran.
            guard case .failure(let error)? = result else { return }
            Task { @MainActor in self?.status = .fan(error) }
        }
    }

    // MARK: - Heat Source Actions

    public func activateProcess(_ source: HeatSource) {
        guard let app = NSRunningApplication(processIdentifier: source.id) else { return }
        app.activate()
    }

    public func terminateProcess(_ source: HeatSource, force: Bool) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        guard source.id > 1 && source.id != selfPID else { return }
        if let app = NSRunningApplication(processIdentifier: source.id) {
            if force {
                _ = app.forceTerminate()
            } else {
                _ = app.terminate()
            }
        } else {
            _ = kill(source.id, force ? SIGKILL : SIGTERM)
        }
        topProcesses.removeAll { $0.id == source.id }
    }

    // MARK: - Launch at Login

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            status = nil
        } catch {
            status = .launchAtLoginFailed(error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
