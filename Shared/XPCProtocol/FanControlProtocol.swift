import Foundation

/// XPC protocol for fan control operations.
/// Shared between the main app (client) and the privileged helper (server).
/// All write operations to the SMC require root privileges and go through this protocol.
@objc protocol FanControlProtocol {
    /// Set a specific fan's minimum RPM.
    /// The fan will run at least this speed; the OS can still increase it for thermal protection.
    /// Pass the original minimum RPM to restore automatic control for that fan.
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
}
