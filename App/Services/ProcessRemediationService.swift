import Foundation
import Darwin

final class ProcessRemediationService: ObservableObject {
    weak var xpc: XPCFanControlService?
    var errorLog: ErrorLog?

    private let queue = DispatchQueue(label: "com.tomsfans.remediation", qos: .userInitiated)

    /// SIGTERM, then SIGKILL escalation after 3 s if still alive.
    func terminate(pid: pid_t, name: String) {
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
        xpc?.sendSignal(SIGKILL, toPID: pid) { _, _ in }
    }
}
