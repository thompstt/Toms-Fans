import Foundation
import Darwin

enum ProcessSampler {
    /// Logical core count (used to normalize raw% to 0–100).
    static let logicalCoreCount: Int = {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.logicalcpu", &count, &size, nil, 0)
        return Int(count > 0 ? count : 1)
    }()

    /// Compute CPU rate from cumulative CPU-time deltas.
    /// - Returns: (rawPct in 0–(100 × cores), normalizedPct in 0–100).
    /// - Edge cases: returns (0, 0) when wallDelta <= 0 or cpuDelta < 0 (process restarted / counter wrap).
    static func computeRate(prevCPUSeconds: Double,
                            currCPUSeconds: Double,
                            prevWall: Date,
                            currWall: Date,
                            logicalCores: Int = logicalCoreCount) -> (rawPct: Double, normalizedPct: Double) {
        let wallDelta = currWall.timeIntervalSince(prevWall)
        guard wallDelta > 0 else { return (0, 0) }
        let cpuDelta = currCPUSeconds - prevCPUSeconds
        guard cpuDelta >= 0 else { return (0, 0) }
        let raw = (cpuDelta / wallDelta) * 100.0
        let normalized = raw / Double(logicalCores)
        return (raw, normalized)
    }

    /// Enumerate all running PIDs via proc_listpids.
    /// Returns empty array on syscall failure — caller should treat this as a degraded-mode signal.
    static func listAllPIDs() -> [pid_t] {
        let maxBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard maxBytes > 0 else { return [] }
        let capacity = Int(maxBytes) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0,
                          buf.baseAddress, Int32(buf.count * MemoryLayout<pid_t>.stride))
        }
        guard written > 0 else { return [] }
        let actualCount = Int(written) / MemoryLayout<pid_t>.stride
        return pids.prefix(actualCount).filter { $0 > 0 }
    }

    /// Cumulative CPU time in seconds for a PID, via proc_pid_rusage.
    /// Returns nil on permission denial or process gone.
    static func cpuTimeSeconds(for pid: pid_t) -> Double? {
        var rusage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &rusage) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
            }
        }
        guard result == 0 else { return nil }
        let nanos = rusage.ri_user_time + rusage.ri_system_time
        return Double(nanos) / 1_000_000_000.0
    }

    /// Resident memory bytes for a PID.
    static func residentMemoryBytes(for pid: pid_t) -> UInt64 {
        var rusage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &rusage) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
            }
        }
        guard result == 0 else { return 0 }
        return rusage.ri_resident_size
    }

    /// Short executable name (no path). Falls back to "<pid>" if unreadable.
    static func name(for pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 1024)
        let written = proc_name(pid, &buf, UInt32(buf.count))
        if written > 0 { return String(cString: buf) }
        return "<\(pid)>"
    }

    /// Full executable path. Empty string if unreadable.
    static func path(for pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096) // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN
        let written = proc_pidpath(pid, &buf, UInt32(buf.count))
        if written > 0 { return String(cString: buf) }
        return ""
    }

    /// Whole-machine CPU usage in percent (0–100), via host_processor_info.
    /// Used as ground truth to cross-check the sum of visible per-PID usage (§6 degraded mode).
    /// Returns nil on Mach call failure.
    static func hostCPUPercent(prev: HostCPUSnapshot?, curr: inout HostCPUSnapshot?) -> Double? {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let snapshot = HostCPUSnapshot(
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3
        )
        defer { curr = snapshot }
        guard let prev else { return nil }
        let userΔ = Double(Int64(snapshot.user) - Int64(prev.user))
        let sysΔ  = Double(Int64(snapshot.system) - Int64(prev.system))
        let niceΔ = Double(Int64(snapshot.nice) - Int64(prev.nice))
        let idleΔ = Double(Int64(snapshot.idle) - Int64(prev.idle))
        let totalΔ = userΔ + sysΔ + niceΔ + idleΔ
        guard totalΔ > 0 else { return nil }
        return ((userΔ + sysΔ + niceΔ) / totalΔ) * 100.0
    }
}

struct HostCPUSnapshot: Equatable {
    let user: natural_t
    let system: natural_t
    let idle: natural_t
    let nice: natural_t
}
