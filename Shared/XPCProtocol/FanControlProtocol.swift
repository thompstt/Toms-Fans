import Foundation

/// XPC protocol for fan control operations.
/// Shared between the main app (client) and the privileged helper (server).
/// All write operations to the SMC require root privileges and go through this protocol.
@objc protocol FanControlProtocol {
    /// Set a specific fan's target RPM (the fan must be in forced mode).
    /// WARNING: forced mode is a hard override — the OS does NOT raise the fan for
    /// thermal protection while a fan is forced (verified: docs/thermal-safety-findings.md).
    /// The helper clamps the value to the fan's hardware min/max.
    func setFanMinSpeed(fanIndex: Int, rpm: Int,
                        withReply reply: @escaping (Bool, String?) -> Void)

    /// Set fan mode (0 = auto, 1 = forced) for a specific fan.
    /// When forced, the fan respects the minimum speed we set rather than the OS thermal policy.
    func setFanMode(fanIndex: Int, mode: UInt8,
                    withReply reply: @escaping (Bool, String?) -> Void)

    /// Restore all fans to automatic control.
    /// Resets modes to auto and minimum speeds to their hardware defaults.
    func restoreAutomaticControl(withReply reply: @escaping (Bool, String?) -> Void)

    /// Get the helper tool version for health checks.
    func getHelperVersion(withReply reply: @escaping (String) -> Void)

    /// Send a POSIX signal (SIGTERM, SIGKILL, SIGSTOP, SIGCONT only) to a PID.
    /// The helper validates the PID server-side against the never-signal list.
    /// Reply: (success, error message or nil).
    func sendSignal(_ signal: Int32, toPID pid: pid_t,
                    withReply reply: @escaping (Bool, String?) -> Void)

    /// Configure the helper-side thermal failsafe. While any fan is forced, the helper
    /// reads `sensorKey` every tick and, if it reaches `ceilingC`, reverts all fans to
    /// auto and refuses further forced writes until the temperature drops below the
    /// hysteresis band. This is the only protection against a misconfigured curve
    /// holding fans low while the chip overheats (forced mode overrides the OS — see
    /// docs/thermal-safety-findings.md). Pass an empty key or ceilingC <= 0 to disable.
    func setThermalGuard(sensorKey: String, ceilingC: Double,
                         withReply reply: @escaping (Bool, String?) -> Void)

    /// Begin duty-cycle throttling a PID: the helper alternately SIGSTOPs and SIGCONTs
    /// it to cap CPU. `level` is the fraction of time suspended (0.0–0.95). The HELPER
    /// owns the full lifecycle (root for both stop and resume — fixing the old EPERM
    /// asymmetry), always leaves the process running on stop/disconnect, never freezes
    /// it for more than one duty slice, and verifies process identity to avoid PID
    /// reuse. Call again with a new level to retune. Validated against the never-signal list.
    func startThrottle(pid: pid_t, level: Double,
                       withReply reply: @escaping (Bool, String?) -> Void)

    /// Stop throttling a PID and guarantee it is resumed (SIGCONT).
    func stopThrottle(pid: pid_t, withReply reply: @escaping (Bool, String?) -> Void)
}
