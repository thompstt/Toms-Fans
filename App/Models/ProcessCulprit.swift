import Foundation

enum ProcessCulprit: Equatable {
    /// A non-excluded process is sustaining heavy CPU and is the likely heat source.
    case candidate(pid: pid_t, name: String, sustainedRawPct: Double)
    /// kernel_task is high — macOS is actively cooling by parking cores. Informational only.
    case macOSCooling
    /// Temps elevated but no CPU process exceeds the threshold (likely GPU/IO).
    case noCPUSource
    /// Sample data can't be trusted (§6). Action buttons hidden.
    case degraded(reason: String)
}
