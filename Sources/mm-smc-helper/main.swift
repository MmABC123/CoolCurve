import Foundation
import CSMCKit
#if canImport(SMCKit)
import SMCKit
#endif

// Elevate to root EUID if installed as a setuid root helper binary
_ = csmc_elevate_root()

let args = Array(CommandLine.arguments.dropFirst())
let client = SMCClient.shared

guard let command = args.first else {
    print("""
    Usage:
      mm-smc-helper status
      mm-smc-helper auto
      mm-smc-helper set <fanIndex> <rpm>
      mm-smc-helper ratio <0.0-1.0>
    """)
    exit(0)
}

switch command {
case "status":
    let snap = client.readThermalSnapshot()
    func temp(_ value: Double) -> String { value > 0 ? String(format: "%.1f°C", value) : "--" }
    let powerStr = client.readSystemPowerWatts().map { String(format: "%.1fW", $0) } ?? "--"
    print("CPU Avg: \(temp(snap.cpuAverageCelsius)) | Peak: \(temp(snap.cpuPeakCelsius)) | "
          + "GPU: \(temp(snap.gpuCelsius)) | Palm: \(temp(snap.palmRestCelsius)) | Chassis: \(temp(snap.chassisCelsius)) | Internal: \(temp(snap.internalCelsius)) | "
          + "Power: \(powerStr) | Ftst: \(snap.hasFtstKey ? "Yes" : "No")")
    if snap.fans.isEmpty {
        print("Fans: 0 (Fanless Mac or Virtual Fan)")
    } else {
        for fan in snap.fans {
            print(String(format: "Fan #%d (%@): %.0f RPM [Min: %.0f, Max: %.0f, Target: %.0f, Manual: %@]",
                         fan.id, fan.name, fan.currentRPM, fan.minRPM, fan.maxRPM, fan.targetRPM,
                         fan.isManualMode ? "YES" : "NO"))
        }
    }
    exit(0)

case "auto":
    let ok = client.restoreAutomaticFanControlDirect()
    if !ok {
        fputs("Failed to restore automatic fan control (root privileges required).\n", stderr)
        exit(1)
    }
    print("Restored automatic fan control.")
    exit(0)

case "set":
    guard args.count >= 3,
          let fanIndex = Int(args[1]),
          let rpm = Double(args[2]) else {
        fputs("Usage: mm-smc-helper set <fanIndex> <rpm>\n", stderr)
        exit(2)
    }
    let ok = client.applyManualFanRPMDirect(fanIndex: fanIndex, rpm: rpm)
    if !ok {
        fputs("Failed to set fan #\(fanIndex) to \(Int(rpm)) RPM (root privileges required).\n", stderr)
        exit(1)
    }
    print("Set fan #\(fanIndex) target to \(Int(rpm)) RPM.")
    exit(0)

case "ratio":
    guard args.count >= 2,
          let ratio = Double(args[1]) else {
        fputs("Usage: mm-smc-helper ratio <0.0-1.0>\n", stderr)
        exit(2)
    }
    let ok = client.applyAllFansPercentageDirect(ratio)
    if !ok {
        fputs("Failed to set fan ratio (root privileges required).\n", stderr)
        exit(1)
    }
    print("Set all fans to \(Int(ratio * 100))%.")
    exit(0)

default:
    fputs("Unknown command: \(command)\n", stderr)
    exit(2)
}
