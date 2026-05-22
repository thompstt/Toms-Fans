import Foundation
import Darwin

final class ProcessRemediationService: ObservableObject {
    weak var xpc: XPCFanControlService?
    var errorLog: ErrorLog?

    private let queue = DispatchQueue(label: "com.tomsfans.remediation", qos: .userInitiated)

    private struct Suspension {
        let pid: pid_t
        let name: String
        let suspendedAt: Date
        let tempsAtSuspend: [String: Double]
        var resumeWorkItem: DispatchWorkItem?
    }
    private var suspendedPIDs: [pid_t: Suspension] = [:]
    private let maxSuspensionSeconds: TimeInterval = 10
    private let earlyResumeTempDropC: Double = 5

    /// SIGTERM, then SIGKILL escalation after 3 s if still alive.
    func terminate(pid: pid_t, name: String) {
        guard !ThermalCorrelator.neverRankNames.contains(name) else {
            errorLog?.logTransient("Refused to signal protected process \(name)", source: .process)
            return
        }
        guard let xpc else {
            errorLog?.logTransient("Cannot terminate \(name) — helper not connected", source: .process)
            return
        }
        xpc.sendSignal(SIGTERM, toPID: pid) { [weak self] success, _ in
            guard success else { return }
            self?.queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                if kill(pid, 0) == 0 {
                    DispatchQueue.main.async {
                        self.xpc?.sendSignal(SIGKILL, toPID: pid) { _, _ in }
                    }
                }
            }
        }
    }

    /// Immediate SIGKILL — no escalation. Caller is responsible for confirmation UX.
    func forceQuit(pid: pid_t, name: String) {
        guard !ThermalCorrelator.neverRankNames.contains(name) else {
            errorLog?.logTransient("Refused to signal protected process \(name)", source: .process)
            return
        }
        xpc?.sendSignal(SIGKILL, toPID: pid) { _, _ in }
    }

    /// SIGSTOP the PID. Auto-resumes after 10s OR when any monitored temperature
    /// drops by 5°C from the suspend-time snapshot (whichever comes first).
    func throttle(pid: pid_t, name: String, currentTemps: [String: Double]) {
        guard !ThermalCorrelator.neverRankNames.contains(name) else {
            errorLog?.logTransient("Refused to signal protected process \(name)", source: .process)
            return
        }
        guard let xpc else {
            errorLog?.logTransient("Cannot throttle \(name) — helper not connected", source: .process)
            return
        }
        if suspendedPIDs[pid] != nil { return }

        xpc.sendSignal(SIGSTOP, toPID: pid) { [weak self] success, _ in
            guard success, let self else { return }

            let resumeWork = DispatchWorkItem { [weak self] in
                DispatchQueue.main.async {
                    self?.resume(pid: pid)
                }
            }
            self.queue.asyncAfter(deadline: .now() + self.maxSuspensionSeconds, execute: resumeWork)

            let suspension = Suspension(
                pid: pid, name: name,
                suspendedAt: Date(),
                tempsAtSuspend: currentTemps,
                resumeWorkItem: resumeWork
            )
            self.suspendedPIDs[pid] = suspension
        }
    }

    /// Single mutation point: removes from suspendedPIDs, cancels the deadline, sends SIGCONT.
    /// Always all three. Idempotent — safe to call multiple times for the same PID.
    /// SIGCONT goes directly via kill() (no XPC dependency); same-user processes don't need root.
    private func resume(pid: pid_t) {
        guard let suspension = suspendedPIDs.removeValue(forKey: pid) else { return }
        suspension.resumeWorkItem?.cancel()
        _ = kill(pid, SIGCONT)
    }

    /// Per-tick check: resume any suspended PID whose monitored temperature
    /// has dropped ≥5°C from the suspend-time snapshot.
    func onTempUpdate(_ temps: [String: Double]) {
        guard !suspendedPIDs.isEmpty else { return }
        let toResume: [pid_t] = suspendedPIDs.compactMap { (pid, suspension) in
            for (sensor, oldValue) in suspension.tempsAtSuspend {
                if let newValue = temps[sensor],
                   (oldValue - newValue) >= earlyResumeTempDropC {
                    return pid
                }
            }
            return nil
        }
        for pid in toResume { resume(pid: pid) }
    }

    /// Synchronously resume every suspended PID. Safety net for sleep, helper disconnect,
    /// safety restore, app quit, and the service's own deinit.
    func resumeAllSuspended() {
        let pids = Array(suspendedPIDs.keys)
        for pid in pids { resume(pid: pid) }
    }

    deinit {
        resumeAllSuspended()
    }
}
