import Foundation
#if canImport(SMCKit)
import SMCKit
#endif

public enum FanControlMode: String, Sendable, Equatable {
    case auto
    case cool
    /// Cooler case than `cool`, at the cost of more fan noise. Replaced the old "turbo" mode.
    case chill
    case manual

    public var isCurveMode: Bool {
        self == .cool || self == .chill
    }

    /// Reads a saved mode, mapping the retired "turbo" to `chill`.
    public init?(storedValue: String) {
        self.init(rawValue: storedValue == "turbo" ? FanControlMode.chill.rawValue : storedValue)
    }
}

/// Errors carry raw detail only; AppState turns them into text in the current language.
public enum FanCommandError: Error, Sendable, Equatable {
    case notAuthorized
    case helperMissing
    case authorizationFailed(String)
    case commandFailed(String)
}

public typealias FanCommandResult = Result<Void, FanCommandError>

/// Reads thermal/fan telemetry and writes fan speeds through the setuid-root `mm-smc-helper`.
public final class FanControlService: @unchecked Sendable {
    public static let helperInstallPath = "/Library/PrivilegedHelperTools/com.fiveamai.mm-smc-helper"

    private let smc = SMCClient.shared

    /// SMC writes run one at a time, in the order they were issued. Without this, a slow ratio write
    /// (M3/M4 `Ftst` unlock waits up to ~1.2s) could land after a later "auto" and re-pin the fans.
    private let commandQueue = DispatchQueue(label: "com.fiveamai.fanline.fan-commands", qos: .userInitiated)
    private let generationLock = NSLock()
    private var latestGeneration = 0

    public init() {}

    /// Queues `work` behind every earlier command; the queue position is fixed when this is called.
    /// `completion` gets nil (and `work` is skipped) when a newer command was submitted while this one
    /// waited, since the newer one decides the final fan state anyway. `completion` runs on the queue.
    public func submit(
        _ work: @escaping @Sendable (FanControlService) -> FanCommandResult,
        completion: @escaping @Sendable (FanCommandResult?) -> Void
    ) {
        let generation = bumpGeneration()
        commandQueue.async {
            guard self.isLatest(generation) else {
                completion(nil)
                return
            }
            completion(work(self))
        }
    }

    /// For app exit: drops queued commands, waits for one already running, then hands fans back to macOS.
    public func restoreAutomaticModeNow() -> FanCommandResult {
        _ = bumpGeneration()
        return commandQueue.sync { restoreAutomaticMode() }
    }

    /// True once any fan command has been issued this session.
    public var hasIssuedCommands: Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return latestGeneration > 0
    }

    private func bumpGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        latestGeneration += 1
        return latestGeneration
    }

    private func isLatest(_ generation: Int) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation == latestGeneration
    }

    public func readSnapshot() -> ThermalSnapshot {
        smc.readThermalSnapshot()
    }

    public func readSystemPowerWatts() -> Double? {
        smc.readSystemPowerWatts()
    }

    /// True when we run as root, or the setuid-root helper is installed.
    public func isHelperAuthorized() -> Bool {
        if geteuid() == 0 { return true }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: Self.helperInstallPath),
              let attrs = try? fm.attributesOfItem(atPath: Self.helperInstallPath),
              let ownerId = attrs[.ownerAccountID] as? NSNumber,
              let posixPerms = attrs[.posixPermissions] as? NSNumber else {
            return false
        }
        return ownerId.intValue == 0 && (posixPerms.intValue & 0o4000) != 0
    }

    /// Prompts once for an administrator password and installs `mm-smc-helper` as setuid root.
    public func authorizePrivilegedHelper() -> FanCommandResult {
        guard let sourcePath = locateBundledHelperBinary() else {
            return .failure(.helperMissing)
        }

        let escapedSource = sourcePath.replacingOccurrences(of: "'", with: "'\\''")
        let destPath = Self.helperInstallPath
        let shellCmd = "mkdir -p /Library/PrivilegedHelperTools && cp -f '\(escapedSource)' '\(destPath)' && chown root:wheel '\(destPath)' && chmod 4755 '\(destPath)'"

        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: "do shell script \"\(shellCmd)\" with administrator privileges") else {
            return .failure(.authorizationFailed("NSAppleScript"))
        }
        _ = script.executeAndReturnError(&errorDict)
        if errorDict == nil && isHelperAuthorized() {
            return .success(())
        }
        let detail = (errorDict?[NSAppleScript.errorMessage] as? String) ?? "cancelled"
        return .failure(.authorizationFailed(detail))
    }

    /// Hands every fan back to macOS automatic thermal control.
    public func restoreAutomaticMode() -> FanCommandResult {
        if geteuid() == 0 {
            return smc.restoreAutomaticFanControlDirect() ? .success(()) : .failure(.commandFailed("SMC write"))
        }
        if isHelperAuthorized() {
            return runHelper(arguments: ["auto"])
        }
        return .failure(.notAuthorized)
    }

    /// Sets all fans to `ratio` (0...1) of the way between their minimum and maximum RPM.
    public func setAllFansRatio(_ ratio: Double) -> FanCommandResult {
        let clamped = min(max(ratio, 0), 1)
        if geteuid() == 0 {
            return smc.applyAllFansPercentageDirect(clamped) ? .success(()) : .failure(.commandFailed("SMC write"))
        }
        if isHelperAuthorized() {
            return runHelper(arguments: ["ratio", String(format: "%.3f", clamped)])
        }
        return .failure(.notAuthorized)
    }

    private func locateBundledHelperBinary() -> String? {
        let fm = FileManager.default
        if let execURL = Bundle.main.executableURL {
            let sibling = execURL.deletingLastPathComponent().appendingPathComponent("mm-smc-helper").path
            if fm.isExecutableFile(atPath: sibling) { return sibling }
        }
        return ["release", "debug"]
            .map { "\(fm.currentDirectoryPath)/.build/\($0)/mm-smc-helper" }
            .first { fm.isExecutableFile(atPath: $0) }
    }

    private func runHelper(arguments: [String]) -> FanCommandResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.helperInstallPath)
        proc.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return .failure(.commandFailed(error.localizedDescription))
        }

        if proc.terminationStatus == 0 {
            return .success(())
        }
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .failure(.commandFailed(err.isEmpty ? "exit \(proc.terminationStatus)" : err))
    }
}
