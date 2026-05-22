import Foundation

final class ThermalCorrelator {
    /// PIDs/names never offered as culprits or remediation targets.
    static let neverRankNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow",
        "logd", "mds", "mds_stores", "com.tomsfans.helper",
        "Tom's Fans"
    ]
    /// A PID counts as "the culprit" when its raw% exceeds this for the required tick count.
    static let candidateRawPctThreshold: Double = 840
    static let candidateConsecutiveTicks = 3
    /// `kernel_task` showing more than this raw% means macOS is in cooling mode.
    static let kernelTaskCoolingThreshold: Double = 200

    private var streakCount: [pid_t: Int] = [:]

    func evaluate(samples: [ProcessSample], thermalState: ProcessInfo.ThermalState) -> ProcessCulprit? {
        let visible = Set(samples.map(\.pid))
        streakCount = streakCount.filter { visible.contains($0.key) }
        for s in samples {
            if s.cpuRawPct > Self.candidateRawPctThreshold,
               !Self.neverRankNames.contains(s.name) {
                streakCount[s.pid, default: 0] += 1
            } else {
                streakCount[s.pid] = 0
            }
        }

        let thermalTrigger = thermalState == .serious || thermalState == .critical
        let streakTrigger = streakCount.values.contains { $0 >= Self.candidateConsecutiveTicks }
        guard thermalTrigger || streakTrigger else { return nil }

        if let kt = samples.first(where: { $0.name == "kernel_task" }),
           kt.cpuRawPct > Self.kernelTaskCoolingThreshold {
            return .macOSCooling
        }

        let streakedPIDs = streakCount.filter { $0.value >= Self.candidateConsecutiveTicks }.keys
        let candidates = samples
            .filter { streakedPIDs.contains($0.pid) && !Self.neverRankNames.contains($0.name) }
            .sorted { $0.cpuRawPct > $1.cpuRawPct }

        if let top = candidates.first {
            return .candidate(pid: top.pid, name: top.name, sustainedRawPct: top.cpuRawPct)
        }

        return .noCPUSource
    }

    func reset() {
        streakCount.removeAll()
    }
}
