import Foundation
import Darwin
import IOKit

/// macOS's own thermal state. `serious` and above means the system is reducing performance.
public enum ThermalLevel: Int, Sendable, Comparable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var isThrottling: Bool { self >= .serious }
}

public enum MemoryPressureLevel: Sendable, Equatable {
    case normal
    case warning
    case critical
}

/// The same signal Activity Monitor's "Memory Pressure" graph is built from.
public struct MemoryPressure: Sendable, Equatable {
    /// 0...100, where higher means the system is closer to running out of memory.
    public var percent: Double
    public var level: MemoryPressureLevel

    public init(percent: Double, level: MemoryPressureLevel) {
        self.percent = percent
        self.level = level
    }
}

/// Battery, AC power adapter, and system power draw snapshot from `AppleSmartBattery`.
public struct PowerStatus: Sendable, Equatable {
    public var hasBattery: Bool
    public var batteryPercent: Int
    public var isOnAC: Bool
    public var isCharging: Bool
    public var systemWatts: Double?

    public init(
        hasBattery: Bool = false,
        batteryPercent: Int = 0,
        isOnAC: Bool = true,
        isCharging: Bool = false,
        systemWatts: Double? = nil
    ) {
        self.hasBattery = hasBattery
        self.batteryPercent = batteryPercent
        self.isOnAC = isOnAC
        self.isCharging = isCharging
        self.systemWatts = systemWatts
    }
}

/// Samples CPU usage and memory pressure via Mach / sysctl (no subprocesses, near-zero overhead).
public final class SystemMonitorService: @unchecked Sendable {
    private var previousCPUTicks: [Int32] = []

    public init() {}

    /// Total CPU usage in percent (0...100), computed from tick deltas since the previous call.
    public func sampleCPU() -> Double {
        var cpuCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &cpuInfo, &infoCount) == KERN_SUCCESS,
              let info = cpuInfo else {
            return 0
        }
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        let current = (0..<Int(infoCount)).map { info[$0] }
        defer { previousCPUTicks = current }
        guard previousCPUTicks.count == current.count else { return 0 }

        let stride = Int(CPU_STATE_MAX)
        var busy: Double = 0
        var total: Double = 0
        for core in 0..<Int(cpuCount) {
            let base = core * stride
            func delta(_ state: Int32) -> Double {
                Double(max(0, current[base + Int(state)] - previousCPUTicks[base + Int(state)]))
            }
            let used = delta(CPU_STATE_USER) + delta(CPU_STATE_SYSTEM) + delta(CPU_STATE_NICE)
            busy += used
            total += used + delta(CPU_STATE_IDLE)
        }
        guard total > 0 else { return 0 }
        return min(max(busy / total * 100.0, 0), 100)
    }

    /// Memory pressure from the kernel's memorystatus subsystem.
    /// `kern.memorystatus_level` is the system-wide "free" percentage (as printed by `memory_pressure`);
    /// `kern.memorystatus_vm_pressure_level` is 1 = normal, 2 = warning, 4 = critical.
    public func sampleMemoryPressure() -> MemoryPressure {
        let freePercent = Self.sysctlInt32("kern.memorystatus_level").map(Double.init) ?? 100
        let rawLevel = Self.sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1

        let level: MemoryPressureLevel
        switch rawLevel {
        case 4...: level = .critical
        case 2...: level = .warning
        default: level = .normal
        }
        return MemoryPressure(percent: min(max(100 - freePercent, 0), 100), level: level)
    }

    public func sampleThermalLevel() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }

    /// GPU busy percent from the IOAccelerator's PerformanceStatistics (no root needed).
    public func sampleGPUUsage() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var usage: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let value = stats["Device Utilization %"] as? NSNumber {
                usage = max(usage ?? 0, value.doubleValue)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return usage.map { min(max($0, 0), 100) }
    }

    /// Battery percentage, AC state, and total system load in Watts from `AppleSmartBattery` (no root needed).
    /// Reads just the battery properties it needs (copying all of AppleSmartBattery's, which include large
    /// nested dictionaries, every 2 seconds was wasted work). `fallbackWatts` is only called when needed.
    public func samplePowerStatus(fallbackWatts: () -> Double? = { nil }) -> PowerStatus {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            return PowerStatus(hasBattery: false, batteryPercent: 0, isOnAC: true, isCharging: false, systemWatts: fallbackWatts())
        }
        defer { IOObjectRelease(service) }

        func prop(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        let installed = (prop("BatteryInstalled") as? Bool) ?? true
        let currentCap = (prop("CurrentCapacity") as? NSNumber)?.intValue ?? 0
        let maxCap = max((prop("MaxCapacity") as? NSNumber)?.intValue ?? 100, 1)
        let percent = min(max(Int((Double(currentCap) / Double(maxCap) * 100.0).rounded()), 0), 100)
        let externalConnected = (prop("ExternalConnected") as? Bool) ?? true
        let isCharging = (prop("IsCharging") as? Bool) ?? false

        var watts: Double?
        if let telemetry = prop("PowerTelemetryData") as? [String: Any],
           let systemLoadMW = (telemetry["SystemLoad"] as? NSNumber)?.doubleValue,
           systemLoadMW > 500 && systemLoadMW < 300_000 {
            watts = systemLoadMW / 1000.0
        } else if !externalConnected,
                  let voltageMV = (prop("Voltage") as? NSNumber)?.doubleValue,
                  let amperageMA = (prop("InstantAmperage") as? NSNumber)?.doubleValue {
            let computed = abs(voltageMV * amperageMA) / 1_000_000.0
            if computed > 0.5 && computed < 300.0 {
                watts = computed
            }
        }

        return PowerStatus(
            hasBattery: installed,
            batteryPercent: percent,
            isOnAC: externalConnected,
            isCharging: isCharging,
            systemWatts: watts ?? fallbackWatts()
        )
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
