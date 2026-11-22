import Foundation
import CSMCKit

public struct FanTelemetry: Identifiable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let currentRPM: Double
    public let minRPM: Double
    public let maxRPM: Double
    public let targetRPM: Double
    public let isManualMode: Bool

    public var loadPercentage: Double {
        guard maxRPM > minRPM else { return 0 }
        let ratio = (currentRPM - minRPM) / (maxRPM - minRPM)
        return min(max(ratio * 100.0, 0.0), 100.0)
    }

    public init(
        id: Int,
        name: String,
        currentRPM: Double,
        minRPM: Double,
        maxRPM: Double,
        targetRPM: Double,
        isManualMode: Bool
    ) {
        self.id = id
        self.name = name
        self.currentRPM = currentRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.targetRPM = targetRPM
        self.isManualMode = isManualMode
    }
}

public struct ThermalSnapshot: Sendable, Equatable {
    public let cpuAverageCelsius: Double
    public let cpuPeakCelsius: Double
    /// Hottest-core aggregate (`TCMz`); spiky, so only for debounced safety checks. 0 = no reading.
    public let cpuHotspotCelsius: Double
    public let gpuCelsius: Double
    public let palmRestCelsius: Double
    /// Hottest of the palm-rest and battery sensors: what you feel on the case. Moves over minutes. 0 = no reading.
    public let chassisCelsius: Double
    /// Interior heat near the heatsink (`TH0x`): rises a minute or two before the chassis does. 0 = no reading.
    public let internalCelsius: Double
    public let fans: [FanTelemetry]
    public let hasFtstKey: Bool

    public init(
        cpuAverageCelsius: Double,
        cpuPeakCelsius: Double,
        cpuHotspotCelsius: Double = 0,
        gpuCelsius: Double,
        palmRestCelsius: Double,
        chassisCelsius: Double = 0,
        internalCelsius: Double = 0,
        fans: [FanTelemetry],
        hasFtstKey: Bool
    ) {
        self.cpuAverageCelsius = cpuAverageCelsius
        self.cpuPeakCelsius = cpuPeakCelsius
        self.cpuHotspotCelsius = cpuHotspotCelsius
        self.gpuCelsius = gpuCelsius
        self.palmRestCelsius = palmRestCelsius
        self.chassisCelsius = chassisCelsius
        self.internalCelsius = internalCelsius
        self.fans = fans
        self.hasFtstKey = hasFtstKey
    }
}

public final class SMCClient: @unchecked Sendable {
    public static let shared = SMCClient()

    private let lock = NSLock()
    private var connection: io_connect_t = 0
    /// Type and size per key, so each later read is one SMC call instead of two.
    private var keyInfo: [String: (type: UInt32, size: UInt32)] = [:]
    /// Keys this Mac's SMC says don't exist; never asked for again (sampling tries many model-specific names).
    private var missingKeys: Set<String> = []
    /// `kIOReturnError`, which `csmc_read_key` returns when the SMC reports a non-zero result (unknown key).
    private static let smcKeyNotFound = kern_return_t(bitPattern: 0xE000_02BC)

    // Common Apple Silicon + Intel CPU temperature SMC keys
    private let cpuTempKeys: [String] = [
        "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
        "TC0P", "TC0D", "TC0E", "TC0F", "TC1C", "TC2C"
    ]

    // Common Apple Silicon + Intel GPU temperature SMC keys. The second row exists on an M3; reading them all
    // matters because a single GPU sensor can briefly report a placeholder (~-1.35°C) while the GPU idles.
    private let gpuTempKeys: [String] = [
        "Tg05", "Tg0D", "Tg0L", "Tg0T", "TG0P", "TG0D",
        "Tg0C", "Tg0O", "Tg0P", "Tg0W", "Tg0X", "Tg0a", "Tg0b", "Tg0i", "Tg0j", "Tg0u", "Tg0v"
    ]

    /// Hottest-core aggregates. `TCMz` read ~10°C above the regular `Tp` keys under load on an M3, but it also
    /// jumps 20°C at idle, so it's reported separately for safety checks rather than mixed into the peak.
    private let cpuHotspotKeys: [String] = ["TCMz"]

    /// Palm rest, left/right. Some firmware spells the first one with a letter O (`TsOP`, seen on an M3).
    private let palmTempKeys: [String] = ["Ts0P", "TsOP", "Ts1P"]

    /// Battery cells, which sit under the palm rest and trackpad.
    private let batteryTempKeys: [String] = ["TB0T", "TB1T", "TB2T"]

    /// Interior heat near the heatsink: `TH0x` (max of `TH0a`/`TH0b`), else the parts.
    private let internalTempKeys: [String] = ["TH0x", "TH0a", "TH0b"]

    public init() {
        _ = ensureConnected()
    }

    deinit {
        lock.lock()
        if connection != 0 {
            csmc_close(connection)
            connection = 0
        }
        lock.unlock()
    }

    @discardableResult
    private func ensureConnected() -> Bool {
        if connection != 0 { return true }
        var conn: io_connect_t = 0
        if csmc_open(&conn) == kIOReturnSuccess && conn != 0 {
            connection = conn
            return true
        }
        return false
    }

    public func readDouble(_ key: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard !missingKeys.contains(key), ensureConnected() else { return nil }

        let info: (type: UInt32, size: UInt32)
        if let cached = keyInfo[key] {
            info = cached
        } else {
            var type: UInt32 = 0
            var size: UInt32 = 0
            let kr = csmc_read_key(connection, key, &type, &size, nil)
            guard kr == kIOReturnSuccess else {
                // kIOReturnError (0xE00002BC) = the SMC answered "no such key"; anything else may be transient.
                if kr == Self.smcKeyNotFound { missingKeys.insert(key) }
                return nil
            }
            info = (type, size)
            keyInfo[key] = info
        }

        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
        return withUnsafeMutableBytes(of: &bytes) { raw -> Double? in
            let buffer = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            guard csmc_read_bytes(connection, key, info.size, buffer) == kIOReturnSuccess else {
                keyInfo[key] = nil
                return nil
            }
            var value: Double = 0
            return csmc_decode_double(info.type, info.size, buffer, &value) ? value : nil
        }
    }

    public func writeDouble(_ key: String, value: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard ensureConnected() else { return false }
        return csmc_write_double(connection, key, value)
    }

    /// Min/max RPM for one fan, shared by telemetry and writes so the UI's % maps to the same RPM we write.
    /// Falls back to typical MacBook Pro values when a key is missing or reports nonsense.
    public func fanRPMRange(fanIndex: Int) -> (min: Double, max: Double) {
        let fallback = (min: 1200.0, max: 6500.0)
        let minRPM = readDouble("F\(fanIndex)Mn").flatMap { $0 > 0 ? $0 : nil } ?? fallback.min
        let maxRPM = readDouble("F\(fanIndex)Mx").flatMap { $0 > 0 ? $0 : nil } ?? fallback.max
        return maxRPM > minRPM ? (minRPM, maxRPM) : fallback
    }

    /// System total power draw in Watts (`PSTR` on Apple Silicon, `PDTR` fallback).
    public func readSystemPowerWatts() -> Double? {
        for key in ["PSTR", "PDTR"] {
            if let watts = readDouble(key), watts > 0.5 && watts < 300.0 {
                return watts
            }
        }
        return nil
    }

    /// Values of `keys` that exist and fall inside `range` (filters out unplugged/garbage sensors).
    private func readings(_ keys: [String], in range: ClosedRange<Double>) -> [Double] {
        keys.compactMap { key in readDouble(key).flatMap { range.contains($0) ? $0 : nil } }
    }

    public func readThermalSnapshot() -> ThermalSnapshot {
        // 1. Read CPU temperatures from SMC keys
        var cpuTemps: [Double] = []
        for key in cpuTempKeys {
            if let t = readDouble(key), t > 18.0 && t < 125.0 {
                cpuTemps.append(t)
            }
        }

        // 2. Fallback to IOHIDEventSystemClient thermal sensors only when no SMC CPU key answered. It is the
        //    most expensive read here (a new client and ~40 sensors per call), and where SMC keys exist the
        //    HID sensors (PMU dies) read 15–20°C lower, so they never changed the result.
        if cpuTemps.isEmpty {
            var hidAvg: Double = 0
            var hidMax: Double = 0
            if csmc_read_hid_temperatures(&hidAvg, &hidMax) > 0 {
                cpuTemps.append(hidAvg)
                if hidMax > hidAvg {
                    cpuTemps.append(hidMax)
                }
            }
        }

        // 0 means "no reading" — callers show "--" rather than a made-up value.
        let cpuAvg = cpuTemps.isEmpty ? 0 : cpuTemps.reduce(0, +) / Double(cpuTemps.count)
        let cpuPeak = cpuTemps.max() ?? 0
        let hotspot = readings(cpuHotspotKeys, in: 18...125).max() ?? 0

        // 3. Read GPU temperature
        var gpuTemps: [Double] = []
        for key in gpuTempKeys {
            if let t = readDouble(key), t > 18.0 && t < 125.0 {
                gpuTemps.append(t)
            }
        }
        let gpuTemp = gpuTemps.isEmpty ? 0 : gpuTemps.reduce(0, +) / Double(gpuTemps.count)

        // 4. Chassis (palm rest + battery) and interior heat
        let palmTemps = readings(palmTempKeys, in: 15...80)
        let batteryTemps = readings(batteryTempKeys, in: 15...80)
        let palmTemp = palmTemps.max() ?? batteryTemps.max() ?? 0
        let chassisTemp = (palmTemps + batteryTemps).max() ?? 0
        let internalTemp = readings(internalTempKeys, in: 15...110).max() ?? 0

        // 5. Read Fans
        let fanCount = Int(readDouble("FNum") ?? 0)
        var fans: [FanTelemetry] = []
        if fanCount > 0 {
            for idx in 0..<fanCount {
                let actual = readDouble("F\(idx)Ac") ?? 0
                let range = fanRPMRange(fanIndex: idx)
                let target = readDouble("F\(idx)Tg") ?? actual
                let modeVal = Int(readDouble("F\(idx)Md") ?? 0)
                let label: String
                if fanCount == 1 {
                    label = "主散热风扇 (Fan 0)"
                } else {
                    label = (idx == 0) ? "左侧风扇 (Left Fan)" : "右侧风扇 (Right Fan)"
                }
                fans.append(
                    FanTelemetry(
                        id: idx,
                        name: label,
                        currentRPM: actual,
                        minRPM: range.min,
                        maxRPM: range.max,
                        targetRPM: target,
                        isManualMode: modeVal == 1
                    )
                )
            }
        }

        let hasFtst = (readDouble("Ftst") != nil)

        return ThermalSnapshot(
            cpuAverageCelsius: cpuAvg,
            cpuPeakCelsius: cpuPeak,
            cpuHotspotCelsius: hotspot,
            gpuCelsius: gpuTemp,
            palmRestCelsius: palmTemp,
            chassisCelsius: chassisTemp,
            internalCelsius: internalTemp,
            fans: fans,
            hasFtstKey: hasFtst
        )
    }

    /// Directly writes SMC fan target RPM (must be executed with root / EUID 0).
    /// Handles both Apple Silicon M1/M2 (`F0Md`/`F0Tg`), M3/M4 (`Ftst` unlock + `F0Md`/`F0Tg`), and Intel (`FS! `).
    public func applyManualFanRPMDirect(fanIndex: Int, rpm: Double) -> Bool {
        let fanCount = Int(readDouble("FNum") ?? 0)
        guard fanIndex >= 0 && fanIndex < fanCount else { return false }

        let range = fanRPMRange(fanIndex: fanIndex)
        let clampedRPM = min(max(rpm, range.min), range.max)

        // Check if M3/M4 `Ftst` key exists and needs unlocking
        if let ftstVal = readDouble("Ftst"), Int(ftstVal) == 0 {
            _ = writeDouble("Ftst", value: 1)
            // Wait briefly for thermalmonitord to yield manual mode control
            for _ in 0..<12 {
                Thread.sleep(forTimeInterval: 0.1)
                if writeDouble("F\(fanIndex)Md", value: 1) {
                    break
                }
            }
        }

        // Set F%dMd = 1 (Manual mode)
        var modeSet = writeDouble("F\(fanIndex)Md", value: 1)

        // Fallback for older Intel SMC using FS! bitmask
        if !modeSet {
            let currentMask = Int(readDouble("FS! ") ?? 0)
            let newMask = currentMask | (1 << fanIndex)
            modeSet = writeDouble("FS! ", value: Double(newMask))
        }

        // Write target RPM to F%dTg
        let targetSet = writeDouble("F\(fanIndex)Tg", value: clampedRPM)
        return modeSet && targetSet
    }

    /// Directly sets all hardware fans to a normalized percentage (0.0 ... 1.0) between minRPM and maxRPM.
    public func applyAllFansPercentageDirect(_ ratio: Double) -> Bool {
        let fanCount = Int(readDouble("FNum") ?? 0)
        guard fanCount > 0 else { return false }
        let clampedRatio = min(max(ratio, 0.0), 1.0)
        var allSucceeded = true
        for idx in 0..<fanCount {
            let range = fanRPMRange(fanIndex: idx)
            let rpm = range.min + (range.max - range.min) * clampedRatio
            if !applyManualFanRPMDirect(fanIndex: idx, rpm: rpm) {
                allSucceeded = false
            }
        }
        return allSucceeded
    }

    /// Restores macOS automatic thermal control for all fans (must be executed with root / EUID 0).
    public func restoreAutomaticFanControlDirect() -> Bool {
        let fanCount = Int(readDouble("FNum") ?? 0)
        var ok = true

        // Clear per-fan manual flags first while `Ftst` (if present on M3/M4) still allows writing `F%dMd`.
        for idx in 0..<fanCount {
            if !writeDouble("F\(idx)Md", value: 0) {
                ok = false
            }
        }

        if readDouble("Ftst") != nil {
            if !writeDouble("Ftst", value: 0) {
                ok = false
            }
        }

        if readDouble("FS! ") != nil {
            _ = writeDouble("FS! ", value: 0)
        }

        return ok
    }
}
