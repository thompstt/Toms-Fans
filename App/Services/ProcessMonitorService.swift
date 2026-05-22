import Foundation
import Combine

final class ProcessMonitorService: ObservableObject {
    /// Latest tick's samples, sorted by cpuRawPct desc.
    @Published private(set) var samples: [ProcessSample] = []
    /// Whole-machine CPU% from host_processor_info (0–100), for the §6 cross-check.
    @Published private(set) var hostCPUPercent: Double = 0

    var errorLog: ErrorLog?

    /// Foreground = full enumeration + ring buffer; background = top-N, no buffer.
    private(set) var foregroundMode = false
    private let backgroundTopN = 15

    /// Previous tick's per-PID cumulative CPU time + wall timestamp.
    private var prevCPUSeconds: [pid_t: (seconds: Double, at: Date)] = [:]
    /// Previous host_processor_info snapshot (for delta-based whole-CPU%).
    private var prevHostSnapshot: HostCPUSnapshot?

    func setForegroundMode(_ on: Bool) {
        foregroundMode = on
    }

    /// Called on every tick from monitor.onPollAlways.
    func sample() {
        let now = Date()
        let allPIDs = ProcessSampler.listAllPIDs()

        var newSamples: [ProcessSample] = []
        newSamples.reserveCapacity(allPIDs.count)

        for pid in allPIDs {
            guard let cpu = ProcessSampler.cpuTimeSeconds(for: pid) else { continue }
            let (raw, normalized): (Double, Double)
            if let prev = prevCPUSeconds[pid] {
                (raw, normalized) = ProcessSampler.computeRate(
                    prevCPUSeconds: prev.seconds,
                    currCPUSeconds: cpu,
                    prevWall: prev.at,
                    currWall: now
                )
            } else {
                (raw, normalized) = (0, 0)
            }
            let name = ProcessSampler.name(for: pid)
            let path = ProcessSampler.path(for: pid)
            let rss = ProcessSampler.residentMemoryBytes(for: pid)
            newSamples.append(ProcessSample(
                pid: pid, name: name, path: path,
                cpuTimeSeconds: cpu, cpuRawPct: raw, cpuNormalizedPct: normalized,
                rssBytes: rss, sampledAt: now
            ))
            prevCPUSeconds[pid] = (cpu, now)
        }

        let visibleSet = Set(allPIDs)
        prevCPUSeconds = prevCPUSeconds.filter { visibleSet.contains($0.key) }

        newSamples.sort { $0.cpuRawPct > $1.cpuRawPct }

        let trimmed = foregroundMode ? newSamples : Array(newSamples.prefix(backgroundTopN))

        var newSnapshot: HostCPUSnapshot? = nil
        let hostPct = ProcessSampler.hostCPUPercent(prev: prevHostSnapshot, curr: &newSnapshot) ?? 0
        prevHostSnapshot = newSnapshot

        DispatchQueue.main.async {
            self.samples = trimmed
            self.hostCPUPercent = hostPct
        }
    }
}
