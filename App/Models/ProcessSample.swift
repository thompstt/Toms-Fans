import Foundation

/// One per-process snapshot from a sampling tick.
struct ProcessSample: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    let path: String
    /// CPU time in seconds since process start (cumulative).
    let cpuTimeSeconds: Double
    /// Computed rate this tick: 0–1600% on a 16-thread machine (one saturated core = 100%).
    let cpuRawPct: Double
    /// Same data, normalized to 0–100 by dividing by logical core count.
    let cpuNormalizedPct: Double
    /// Resident memory in bytes.
    let rssBytes: UInt64
    /// Timestamp of this sample.
    let sampledAt: Date

    var id: pid_t { pid }
}
