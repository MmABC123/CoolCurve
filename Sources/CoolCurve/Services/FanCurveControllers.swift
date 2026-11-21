import Foundation

/// One sample of what the curve controllers look at. Temperatures in °C (0 = no reading), usage in 0...100.
struct FanControlInputs {
    var cpuAverage: Double
    var cpuPeak: Double
    /// Interior heat near the heatsink (`TH0x`).
    var interior: Double
    /// Hottest of palm rest / battery.
    var chassis: Double
    var cpuUsage: Double
    var gpuUsage: Double
    /// macOS thermal state is `fair` or worse.
    var isWarm: Bool
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

/// Cool: keep the case from warming up, quietly. Always drives the fans (never hands back to macOS),
/// never stops them, and changes speed slowly in both directions.
///
/// - Main signal: interior heat (`TH0x`), which leads the chassis by a minute or two and is smooth by nature.
/// - Also tracks a slowly smoothed CPU average, so heat is removed before it reaches the case.
/// - Long-term trim: if palm rest/battery sit above `chassisTarget`, speed creeps up until they come back.
///   The trim goes on top of the noise cap: keeping the case cool wins over keeping quiet.
/// - Noise cap of 60% on the temperature-driven part unless the CPU is really hot or macOS is throttling.
struct QuietFanController {
    static let cpuCurve = LinearCurve(points: [(50, 0), (65, 0.25), (75, 0.45), (85, 0.60), (92, 0.85)])
    static let internalCurve = LinearCurve(points: [(35, 0), (37, 0.25), (39, 0.45), (42, 0.70)])
    static let chassisTarget = 35.0
    /// 1°C over target for one minute adds 1.5%.
    static let trimPerDegreeSecond = 0.00025
    static let maxTrim = 0.30
    static let noiseCap = 0.60
    /// Smoothed CPU average at/above this lifts the noise cap (and ramps 4× faster).
    static let capLiftCelsius = 85.0
    static let risePerSecond = 0.01
    static let fallPerSecond = 0.005
    static let holdBeforeFall: TimeInterval = 30

    private var cpuSmoothed: Double?
    private var internalSmoothed: Double?
    private var trim = 0.0
    private var slew = SlewLimiter()

    /// Starts from the fan's current position so switching modes doesn't jump.
    mutating func reset(startingAt ratio: Double) {
        cpuSmoothed = nil
        internalSmoothed = nil
        trim = 0
        slew.reset(to: ratio, hold: Self.holdBeforeFall)
    }

    /// Returns the fan ratio (0...1) to run at.
    mutating func step(_ input: FanControlInputs) -> Double {
        let dt = input.interval
        let cpu = input.cpuAverage > 0 ? smooth(&cpuSmoothed, input.cpuAverage, tau: 45, dt: dt) : 0
        let interior = input.interior > 0 ? smooth(&internalSmoothed, input.interior, tau: 10, dt: dt) : 0

        let isHot = cpu >= Self.capLiftCelsius || input.isThrottling
        let heat = max(Self.cpuCurve(cpu), interior > 0 ? Self.internalCurve(interior) : 0)
        var target = min(heat, isHot ? 1.0 : Self.noiseCap)

        if input.chassis > 0 {
            trim += (input.chassis - Self.chassisTarget) * Self.trimPerDegreeSecond * dt
            trim = min(max(trim, 0), Self.maxTrim)
        }
        target = min(target + trim, 1.0)

        return slew.step(
            toward: target,
            risePerSecond: Self.risePerSecond * (isHot ? 4 : 1),
            fallPerSecond: Self.fallPerSecond,
            holdBeforeFall: Self.holdBeforeFall,
            dt: dt
        )
    }
}

/// Turbo: a more eager take on macOS auto. Starts earlier, reacts to load before temperatures climb,
/// jumps up immediately, and hands the fans back to macOS once things have been cool for a minute.
struct TurboFanController {
    static let tempCurve = LinearCurve(points: [(58, 0.20), (70, 0.50), (80, 0.80), (88, 1.0)])
    /// Feed-forward from CPU/GPU busy %: spin up as load arrives instead of waiting for heat.
    static let loadCurve = LinearCurve(points: [(40, 0), (60, 0.30), (90, 0.60)])
    static let engageCelsius = 58.0
    static let engageLoad = 60.0
    /// Release once a slowly smoothed temperature stays at/below this (idle on an M3 MBP sits ~48–52°C).
    static let releaseCelsius = 54.0
    static let releaseAfter: TimeInterval = 60
    static let fallPerSecond = 0.02
    static let holdBeforeFall: TimeInterval = 15

    private var tempSmoothed: Double?
    /// Slower view of the same temperature for the release decision, so idle jitter doesn't reset the countdown.
    private var releaseSmoothed: Double?
    private var isEngaged = false
    private var coolFor: TimeInterval = 0
    private var slew = SlewLimiter()

    mutating func reset(startingAt ratio: Double) {
        tempSmoothed = nil
        releaseSmoothed = nil
        isEngaged = false
        coolFor = 0
        slew.reset(to: ratio)
    }

    /// Returns the fan ratio (0...1) to run at, or nil to leave the fans to macOS.
    mutating func step(_ input: FanControlInputs) -> Double? {
        let dt = input.interval
        let raw = max(input.cpuAverage, input.cpuPeak - 5)
        guard raw > 0 else { return isEngaged ? slew.output : nil }
        let temp = smooth(&tempSmoothed, raw, tau: 3, dt: dt)
        let slowTemp = smooth(&releaseSmoothed, raw, tau: 20, dt: dt)
        let load = max(input.cpuUsage, input.gpuUsage)

        if !isEngaged {
            guard temp >= Self.engageCelsius || load >= Self.engageLoad || input.isWarm else { return nil }
            isEngaged = true
            coolFor = 0
        } else if slowTemp <= Self.releaseCelsius && Self.loadCurve(load) == 0 && !input.isWarm {
            coolFor += dt
            if coolFor >= Self.releaseAfter {
                isEngaged = false
                coolFor = 0
                slew.reset(to: 0)
                return nil
            }
        } else {
            coolFor = 0
        }

        let target = max(Self.tempCurve(temp), Self.loadCurve(load))
        return slew.step(
            toward: target,
            risePerSecond: .infinity,
            fallPerSecond: Self.fallPerSecond,
            holdBeforeFall: Self.holdBeforeFall,
            dt: dt
        )
    }
}
