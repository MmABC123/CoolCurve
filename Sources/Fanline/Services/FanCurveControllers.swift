import Foundation

/// One sample of what the curve controllers look at. Temperatures in °C (0 = no reading), usage in 0...100.
struct FanControlInputs {
    var cpuAverage: Double
    var cpuPeak: Double
    /// Hottest-core aggregate (`TCMz`); spiky, so only used smoothed.
    var cpuHotspot: Double
    /// Interior heat near the heatsink (`TH0x`).
    var interior: Double
    /// Hottest of palm rest / battery.
    var chassis: Double
    var cpuUsage: Double
    var gpuUsage: Double
    /// macOS thermal state is `serious` or worse.
    var isThrottling: Bool
    /// Seconds since the previous sample.
    var interval: TimeInterval
}

/// Piecewise-linear map, flat beyond the first and last points.
struct LinearCurve {
    let points: [(x: Double, y: Double)]

    func callAsFunction(_ x: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        for (a, b) in zip(points, points.dropFirst()) where x <= b.x {
            return a.y + (b.y - a.y) * (x - a.x) / max(b.x - a.x, .ulpOfOne)
        }
        return last.y
    }
}

/// Exponential smoothing with a time constant, so behaviour doesn't depend on the sample rate.
private func smooth(_ previous: inout Double?, _ value: Double, tau: TimeInterval, dt: TimeInterval) -> Double {
    guard let prev = previous else {
        previous = value
        return value
    }
    let alpha = 1 - exp(-dt / tau)
    let next = prev + (value - prev) * alpha
    previous = next
    return next
}

/// Moves `output` toward `target`: rising at `risePerSecond`, falling at `fallPerSecond` only after
/// `holdBeforeFall` seconds without a rise (so a brief dip in load doesn't make the fan hunt).
private struct SlewLimiter {
    var output: Double = 0
    private var holdRemaining: TimeInterval = 0

    /// Keeps the current output for at least `seconds` more before it may start falling.
    mutating func hold(atLeast seconds: TimeInterval) {
        holdRemaining = max(holdRemaining, seconds)
    }

    /// Starts at `value` and holds it for `hold` seconds, so a mode switch doesn't immediately dip the fan.
    mutating func reset(to value: Double, hold: TimeInterval = 0) {
        output = min(max(value, 0), 1)
        holdRemaining = hold
    }

    mutating func step(
        toward target: Double,
        risePerSecond: Double,
        fallPerSecond: Double,
        holdBeforeFall: TimeInterval,
        dt: TimeInterval
    ) -> Double {
        if target > output + 1e-6 {
            output = min(target, output + risePerSecond * dt)
            holdRemaining = holdBeforeFall
        } else {
            holdRemaining = max(0, holdRemaining - dt)
            if target < output && holdRemaining == 0 {
                output = max(target, output - fallPerSecond * dt)
            }
        }
        return output
    }
}

/// How much noise a chassis-first mode trades for a cooler case.
struct ChassisFanProfile {
    /// Fan never goes below this (0 = hardware minimum RPM, still spinning).
    let floor: Double
    /// Target from a slowly smoothed CPU average.
    let cpuCurve: LinearCurve
    /// Target from interior heat (`TH0x`), which leads the chassis by a minute or two.
    let internalCurve: LinearCurve
    /// Feed-forward from smoothed CPU/GPU busy %: start moving heat before temperatures show it. nil = off.
    let loadCurve: LinearCurve?
    /// Palm rest / battery above this slowly adds speed, on top of the noise cap.
    let chassisTarget: Double
    /// Ceiling for the temperature-driven part until the shared high-temperature layer takes over.
    let noiseCap: Double
    let risePerSecond: Double
    let fallPerSecond: Double
    let holdBeforeFall: TimeInterval

    /// Cool: quiet first. Hardware-minimum floor, gentle curves, 60% cap.
    static let cool = ChassisFanProfile(
        floor: 0,
        cpuCurve: LinearCurve(points: [(50, 0), (65, 0.25), (75, 0.45), (85, 0.60), (92, 0.85)]),
        internalCurve: LinearCurve(points: [(35, 0), (37, 0.25), (39, 0.45), (42, 0.70)]),
        loadCurve: nil,
        chassisTarget: 35,
        noiseCap: 0.60,
        risePerSecond: 0.01,
        fallPerSecond: 0.005,
        holdBeforeFall: 30
    )

    /// Chill: cool case first. ~20% floor to keep heat from soaking in, curves ~5°C earlier,
    /// load feed-forward, faster rise, slower to back off, 80% cap.
    static let chill = ChassisFanProfile(
        floor: 0.20,
        cpuCurve: LinearCurve(points: [(45, 0.20), (60, 0.35), (70, 0.55), (80, 0.75), (87, 0.95)]),
        internalCurve: LinearCurve(points: [(34, 0.20), (36, 0.35), (38, 0.50), (41, 0.75)]),
        loadCurve: LinearCurve(points: [(30, 0), (50, 0.35), (80, 0.60)]),
        chassisTarget: 33,
        noiseCap: 0.80,
        risePerSecond: 0.02,
        fallPerSecond: 0.005,
        holdBeforeFall: 60
    )
}

/// Chassis-first fan control shared by Cool and Chill: always drives the fans (never hands back to macOS),
/// never stops them, changes speed gradually, and steers mainly by interior heat and a slow CPU average,
/// with a long-term trim on palm rest / battery temperature.
///
/// Both profiles share one high-temperature layer: once a ~10s-smoothed CPU peak (including `TCMz`)
/// reaches `hotCelsius`, or macOS is throttling, the noise cap goes away, a floor from `hotCurve`
/// applies, and the fan ramps 4× faster. It stays on until the peak drops below `hotExitCelsius`, then
/// holds the speed for `hotExitHold` before easing down — without that gap a peak hovering at the
/// threshold made the fan swing between ~48% and ~76% every minute. While hot, the speed follows a
/// slower (~40s) view of the peak, because `TCMz` spikes ±5°C from second to second.
struct ChassisFanController {
    static let hotCelsius = 85.0
    static let hotExitCelsius = 80.0
    static let hotExitHold: TimeInterval = 60
    static let hotCurve = LinearCurve(points: [(85, 0.60), (95, 1.0)])
    /// 1°C over the chassis target for one minute adds 1.5%.
    static let trimPerDegreeSecond = 0.00025
    static let maxTrim = 0.30

    let profile: ChassisFanProfile

    private var cpuSmoothed: Double?
    private var internalSmoothed: Double?
    private var loadSmoothed: Double?
    private var peakSmoothed: Double?
    private var slowPeakSmoothed: Double?
    private var trim = 0.0
    private var isHot = false
    private var slew = SlewLimiter()

    init(profile: ChassisFanProfile) {
        self.profile = profile
    }

    /// Starts from the fan's current position (holding it briefly) so switching modes doesn't jump.
    mutating func reset(startingAt ratio: Double) {
        cpuSmoothed = nil
        internalSmoothed = nil
        loadSmoothed = nil
        peakSmoothed = nil
        slowPeakSmoothed = nil
        trim = 0
        isHot = false
        slew.reset(to: ratio, hold: profile.holdBeforeFall)
    }

    /// Returns the fan ratio (0...1) to run at.
    mutating func step(_ input: FanControlInputs) -> Double {
        let dt = input.interval
        let cpu = input.cpuAverage > 0 ? smooth(&cpuSmoothed, input.cpuAverage, tau: 45, dt: dt) : 0
        let interior = input.interior > 0 ? smooth(&internalSmoothed, input.interior, tau: 10, dt: dt) : 0
        let load = smooth(&loadSmoothed, max(input.cpuUsage, input.gpuUsage), tau: 20, dt: dt)
        let rawPeak = max(input.cpuPeak, input.cpuHotspot, input.cpuAverage)
        let peak = rawPeak > 0 ? smooth(&peakSmoothed, rawPeak, tau: 10, dt: dt) : 0
        let slowPeak = rawPeak > 0 ? smooth(&slowPeakSmoothed, rawPeak, tau: 40, dt: dt) : 0

        if input.isThrottling || peak >= Self.hotCelsius {
            isHot = true
        } else if isHot && peak < Self.hotExitCelsius {
            isHot = false
            slew.hold(atLeast: Self.hotExitHold)
        }
        var heat = max(profile.cpuCurve(cpu), interior > 0 ? profile.internalCurve(interior) : 0)
        if let loadCurve = profile.loadCurve {
            heat = max(heat, loadCurve(load))
        }
        var target = isHot ? max(heat, Self.hotCurve(slowPeak)) : min(heat, profile.noiseCap)

        if input.chassis > 0 {
            trim += (input.chassis - profile.chassisTarget) * Self.trimPerDegreeSecond * dt
            trim = min(max(trim, 0), Self.maxTrim)
        }
        target = min(max(target + trim, profile.floor), 1.0)

        return slew.step(
            toward: target,
            risePerSecond: profile.risePerSecond * (isHot ? 4 : 1),
            fallPerSecond: profile.fallPerSecond,
            holdBeforeFall: isHot ? max(profile.holdBeforeFall, Self.hotExitHold) : profile.holdBeforeFall,
            dt: dt
        )
    }
}

extension ChassisFanProfile {
    static func forMode(_ mode: FanControlMode) -> ChassisFanProfile? {
        switch mode {
        case .cool: return .cool
        case .chill: return .chill
        case .auto, .manual: return nil
        }
    }

    /// What this profile asks for at a given CPU temperature, ignoring the slower inputs (interior heat,
    /// load, chassis trim). Used to draw the mode's curve; the live controller can sit above or below it.
    func previewRatio(atCPU celsius: Double) -> Double {
        let heat = cpuCurve(celsius)
        let value = celsius >= ChassisFanController.hotCelsius
            ? max(heat, ChassisFanController.hotCurve(celsius))
            : min(heat, noiseCap)
        return min(max(value, floor), 1)
    }
}
