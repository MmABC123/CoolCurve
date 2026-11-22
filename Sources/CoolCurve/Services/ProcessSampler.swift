import Foundation
import Darwin
import AppKit

/// A process using noticeable CPU since the previous sample.
public struct HeatSource: Identifiable, Sendable, Equatable {
    public let id: pid_t
    public let name: String
    /// Percent of one core, Activity Monitor style (can exceed 100 on multi-threaded work).
    public let cpuPercent: Double
    /// True when the process is a regular GUI application that can be activated.
    public let isApplication: Bool

    public init(id: pid_t, name: String, cpuPercent: Double, isApplication: Bool) {
        self.id = id
        self.name = name
        self.cpuPercent = cpuPercent
        self.isApplication = isApplication
    }
}

/// Finds the busiest processes via libproc (no `ps` subprocess). Processes owned by other users
/// (e.g. WindowServer, kernel_task) can't be read without root and are skipped.
public final class ProcessSampler: @unchecked Sendable {
    private var previousCPUTime: [pid_t: UInt64] = [:]
    private var previousTimestamp: UInt64 = 0
    private let timebaseNumer: UInt64
    private let timebaseDenom: UInt64

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebaseNumer = UInt64(max(info.numer, 1))
        timebaseDenom = UInt64(max(info.denom, 1))
    }

    /// Forgets the previous sample, so the next one only sets a baseline. Call when sampling pauses,
    /// otherwise the first sample after a long gap would average CPU over the whole gap.
    public func reset() {
        previousCPUTime = [:]
        previousTimestamp = 0
    }

    public func sampleTopProcesses(limit: Int = 3) -> [HeatSource] {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }

        var current: [pid_t: UInt64] = [:]
        current.reserveCapacity(Int(count))
        var deltas: [(pid: pid_t, delta: UInt64)] = []

        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard let cpuTime = cpuTimeNanoseconds(of: pid) else { continue }
            current[pid] = cpuTime
            if let previous = previousCPUTime[pid], cpuTime > previous {
                let delta = cpuTime - previous
                if delta > 0 {
                    deltas.append((pid, delta))
                }
            }
        }

        let elapsed = previousTimestamp > 0 && now > previousTimestamp ? now - previousTimestamp : 0
        previousCPUTime = current
        previousTimestamp = now

        guard elapsed > 0, !deltas.isEmpty else { return [] }
        deltas.sort { $0.delta > $1.delta }

        var results: [HeatSource] = []
        for entry in deltas.prefix(max(limit, 1)) {
            let pct = Double(entry.delta) / Double(elapsed) * 100
            if pct < 1.0 && !results.isEmpty { break }
            let app = NSRunningApplication(processIdentifier: entry.pid)
            let isRegularApp = app?.activationPolicy == .regular
            let name = app?.localizedName ?? Self.processName(of: entry.pid)
            results.append(HeatSource(id: entry.pid, name: name, cpuPercent: pct, isApplication: isRegularApp))
        }
        return results
    }

    /// User + system CPU time. rusage reports Mach ticks on Apple Silicon, so convert with the timebase.
    private func cpuTimeNanoseconds(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        let ticks = info.ri_user_time &+ info.ri_system_time
        return ticks &* timebaseNumer / timebaseDenom
    }

    private static func processName(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            return String(cString: buffer)
        }
        return "pid \(pid)"
    }
}
