import Foundation

final class ProcessMonitorService: ObservableObject {
    /// Latest tick's samples, sorted by cpuRawPct desc.
    @Published private(set) var samples: [ProcessSample] = []
    /// Whole-machine CPU% from host_processor_info (0–100), for the §6 cross-check.
    @Published private(set) var hostCPUPercent: Double = 0
    @Published private(set) var culprit: ProcessCulprit?

    var errorLog: ErrorLog?

    /// Foreground = full enumeration + ring buffer; background = top-N, no buffer.
    private(set) var foregroundMode = false
    private let backgroundTopN = 15

    /// Previous tick's per-PID cumulative CPU time + wall timestamp.
    private var prevCPUSeconds: [pid_t: (seconds: Double, at: Date)] = [:]
    /// Previous host_processor_info snapshot (for delta-based whole-CPU%).
    private var prevHostSnapshot: HostCPUSnapshot?

    private let correlator = ThermalCorrelator()
    private var lastThermalState: ProcessInfo.ThermalState = .nominal

    /// Per-PID rolling history. Only populated in foreground mode; pruned to 60s on each insert.
    private var ringBuffer: [pid_t: [ProcessSample]] = [:]
    private let ringBufferDuration: TimeInterval = 60

    private let workQueue = DispatchQueue(label: "com.tomsfans.processMonitor", qos: .userInitiated)

    init() {
        lastThermalState = ProcessInfo.processInfo.thermalState
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.lastThermalState = ProcessInfo.processInfo.thermalState
        }
    }

    func setForegroundMode(_ on: Bool) {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.foregroundMode = on
            if !on {
                self.ringBuffer.removeAll()
            }
        }
    }

    /// Called on every tick from monitor.onPollAlways.
    func sample() {
        workQueue.async { [weak self] in
            guard let self else { return }

            let now = Date()
            let allPIDs = ProcessSampler.listAllPIDs()

            var newSamples: [ProcessSample] = []
            newSamples.reserveCapacity(allPIDs.count)

            for pid in allPIDs {
                guard let cpu = ProcessSampler.cpuTimeSeconds(for: pid) else { continue }
                let (raw, normalized): (Double, Double)
                if let prev = self.prevCPUSeconds[pid] {
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
                self.prevCPUSeconds[pid] = (cpu, now)
            }

            let visibleSet = Set(allPIDs)
            self.prevCPUSeconds = self.prevCPUSeconds.filter { visibleSet.contains($0.key) }

            newSamples.sort { $0.cpuRawPct > $1.cpuRawPct }

            let trimmed = self.foregroundMode ? newSamples : Array(newSamples.prefix(self.backgroundTopN))

            var newSnapshot: HostCPUSnapshot? = nil
            let hostPct = ProcessSampler.hostCPUPercent(prev: self.prevHostSnapshot, curr: &newSnapshot) ?? 0
            self.prevHostSnapshot = newSnapshot

            if self.foregroundMode {
                let cutoff = now.addingTimeInterval(-self.ringBufferDuration)
                for s in newSamples {
                    var hist = self.ringBuffer[s.pid] ?? []
                    hist.append(s)
                    if let firstKeep = hist.firstIndex(where: { $0.sampledAt >= cutoff }), firstKeep > 0 {
                        hist.removeFirst(firstKeep)
                    }
                    self.ringBuffer[s.pid] = hist
                }
                self.ringBuffer = self.ringBuffer.filter { visibleSet.contains($0.key) }
            }

            DispatchQueue.main.async {
                self.samples = trimmed
                self.hostCPUPercent = hostPct
                self.culprit = self.correlator.evaluate(samples: trimmed, thermalState: self.lastThermalState)
            }
        }
    }
}
