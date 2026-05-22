# Task Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a thermal-aware task manager to Tom's Fans that samples per-process CPU/memory on the existing thermal poll loop, identifies likely heat culprits via correlation, and offers one-click manual remediation (Quit / Force Quit / Throttle) routed through the existing privileged XPC helper.

**Architecture:** Two new services (`ProcessMonitorService`, `ProcessRemediationService`) plug into the existing `monitor.onPoll` heartbeat — no second timer. The XPC helper gets one new method (`sendSignal`) with server-side validation. A bounded `SIGSTOP`/`SIGCONT` throttle invariant guarantees no process stays suspended past any teardown path (sleep, helper disconnect, safety restore, app quit). When process data can't be trusted (low PID count or visible-CPU gap), the feature falls back to "macOS thermal management is in control" and hides all action buttons.

**Tech Stack:** Swift / SwiftUI, AppKit lifecycle, NSXPCConnection, BSD `proc_*` syscalls (`proc_listpids`, `proc_pid_rusage`, `proc_pidpath`, `proc_name`), Mach `host_processor_info`, POSIX `kill()`, `UserNotifications`. Project uses xcodegen (`project.yml`) — new files under `App/` `Shared/` `Helper/` are picked up automatically.

**Design spec:** `docs/superpowers/specs/2026-05-22-task-manager-design.md`

---

## File Map

**Create:**
- `App/Models/ProcessSample.swift` — per-PID sample struct (pid, name, path, cpuRawPct, cpuNormalizedPct, rssBytes)
- `App/Models/ProcessCulprit.swift` — `enum ProcessCulprit { case candidate(...); case macOSCooling; case noCPUSource; case degraded(reason) }`
- `App/Services/ProcessSampler.swift` — pure helpers: `proc_listpids` wrapping, rate computation, sum-vs-host check (statically testable)
- `App/Services/ProcessMonitorService.swift` — `@StateObject` that runs sampling each tick, owns ring buffer, owns `ThermalCorrelator`
- `App/Services/ThermalCorrelator.swift` — trigger + ranking logic; emits `ProcessCulprit?`
- `App/Services/ProcessRemediationService.swift` — `@StateObject` that owns `suspendedPIDs`, schedules resume work items, calls XPC
- `App/Views/Components/ProcessListView.swift` — sortable table view of current samples
- `App/Views/Components/CulpritCardView.swift` — informational + action variants
- `App/Debug/ProcessMonitorDebugHarness.swift` (under `#if DEBUG`) — fixture-driven sanity checks for the pure functions

**Modify:**
- `App/TomsFansApp.swift` — add two `@StateObject`s, extend `bootstrapIfNeeded()`, `setupPollCallback()`, `setupSafetyCallbacks()`, `observeSleepWake()`, `AppDelegate.applicationWillTerminate`, and window `onAppear`/`onDisappear`
- `App/Services/SMCMonitorService.swift` — add `onPollAlways: (() -> Void)?` callback that fires every tick (existing `onPoll` only fires on temp delta ≥ 1°C, but process sampling needs to run every tick to catch a runaway before it heats anything)
- `App/Models/AppSettings.swift` — add `processMonitoringEnabled`, `remediationEnabled`, `cpuDisplayMode`
- `App/Services/NotificationService.swift` — add `notifyCulprit(_:)` and a one-shot `notifyDegraded()` (coalesced per session)
- `App/Services/ErrorLog.swift` — add `.process` case to `ErrorSource`
- `Shared/XPCProtocol/FanControlProtocol.swift` — add `sendSignal(_:toPID:withReply:)`
- `App/Services/XPCFanControlService.swift` — add `sendSignal(_:toPID:completion:)` convenience wrapper
- `Helper/FanControlServiceImpl.swift` — implement `sendSignal` with server-side validation and `kill()`
- `App/Views/Main/DashboardView.swift` — render `ProcessListView` and `CulpritCardView` when `settings.processMonitoringEnabled`
- `App/Views/Main/SettingsView.swift` — add toggles for `processMonitoringEnabled` and `remediationEnabled`
- `README.md` — document the v1 crash-gap limitation (suspended PIDs orphaned if app crashes)

---

## Important codebase facts to honor

- **`monitor.onPoll` is gated:** it only fires when at least one temperature changed by ≥ 1°C (see `SMCMonitorService.swift:282-284`). Curve engine and notifications are fine with this, but **process sampling needs to run every tick** to detect a runaway *before* heat appears. The plan adds `onPollAlways` to `SMCMonitorService` rather than changing `onPoll`'s semantics.
- **XPC protocol convention:** existing methods use `withReply reply: @escaping (Bool, String?) -> Void` where `String?` is the error message. Match this — don't introduce `NSError`-based replies.
- **Safety-restore fan-out:** the `restore` closure in `setupSafetyCallbacks()` (`TomsFansApp.swift:137-143`) is wired into three sources (`monitor.onSafetyRestore`, `curveEngine.onSafetyRestore`, `fanControl.onDisconnect`). Remediation's `resumeAllSuspended()` must be called from inside `restore` **before** the existing fan-restore logic.
- **`AppDelegate.applicationWillTerminate`** currently just sets `isTerminating = true`. Needs to also call `resumeAllSuspended()` synchronously.
- **No XCTest target exists.** Spec defers it. Pure-logic verification goes in `App/Debug/ProcessMonitorDebugHarness.swift` under `#if DEBUG`, called from a hidden "Run Debug Harness" menu item or `bootstrapIfNeeded()` printout.
- **xcodegen:** project rebuilds via `xcodegen generate` after adding files — `project.yml` enumerates by path, no file lists.
- **`ErrorLog.ErrorSource`** is missing a `.process` case — add it before logging from new services.

---

## Build Order Overview

1. Add `onPollAlways` to `SMCMonitorService`.
2. Add `AppSettings` flags + `.process` to `ErrorSource`.
3. `ProcessSample` model + `ProcessSampler` pure functions + debug harness.
4. `ProcessMonitorService` — sampling each tick (no UI yet).
5. Foreground/background mode + 60s ring buffer.
6. Bare-bones `ProcessListView` wired into `DashboardView` (verify against Activity Monitor).
7. `ProcessCulprit` model + `ThermalCorrelator`.
8. Degraded-mode detection.
9. XPC helper protocol extension + helper-side `sendSignal`.
10. `ProcessRemediationService` — `terminate` action first (TERM→KILL escalation).
11. `throttle` action with bounded SIGSTOP/CONT + the three resume triggers.
12. Wire `resumeAllSuspended()` into every teardown path.
13. **Run the manual safety-invariant checklist (from spec §8.1).**
14. `CulpritCardView` + Force Quit confirm sheet (gated on `remediationEnabled`).
15. Background notification on culprit + degraded entry.
16. Settings toggles + README crash-gap note.

---

## Task 1: Add `onPollAlways` callback to `SMCMonitorService`

**Files:**
- Modify: `App/Services/SMCMonitorService.swift`

**Why:** The existing `onPoll` only fires when temperatures change by ≥ 1°C. Process sampling needs to run every tick to detect a CPU runaway *before* heat builds. Adding a peer callback that always fires is the smallest non-invasive change.

- [ ] **Step 1: Add the property next to `onPoll`**

In `SMCMonitorService.swift`, find the line `var onPoll: (([TemperatureSensor]) -> Void)?` (around line 41). Add immediately after:

```swift
/// Fires on every poll tick, regardless of temperature delta.
/// Use for samplers that need a heartbeat independent of temperature changes
/// (e.g. process sampling, where load is a leading indicator of heat).
var onPollAlways: (() -> Void)?
```

- [ ] **Step 2: Invoke it inside `poll()`**

In `poll()`, find the block starting `if tempsChanged { self.onPoll?(updatedTemps) }` (around line 282-284). Add immediately after that block (still inside the `DispatchQueue.main.async`):

```swift
// Always-fires heartbeat for samplers that don't depend on temp changes.
self.onPollAlways?()
```

- [ ] **Step 3: Build and run the app**

Run: `xcodegen generate && xcodebuild -project "Tom's Fans.xcodeproj" -scheme "Tom's Fans" -configuration Debug build`
Expected: clean build (no warnings/errors).

- [ ] **Step 4: Commit**

```bash
git add App/Services/SMCMonitorService.swift
git commit -m "Add onPollAlways heartbeat to SMCMonitorService"
```

---

## Task 2: Add `AppSettings` flags and `.process` error source

**Files:**
- Modify: `App/Models/AppSettings.swift`
- Modify: `App/Services/ErrorLog.swift`

- [ ] **Step 1: Add `.process` to `ErrorSource`**

In `App/Services/ErrorLog.swift`, change the `ErrorSource` enum to:

```swift
enum ErrorSource: String {
    case smc = "SMC"
    case xpc = "XPC"
    case process = "Process"
}
```

- [ ] **Step 2: Add `CPUDisplayMode` enum + three properties to `AppSettings`**

In `App/Models/AppSettings.swift`, add this enum at top-level (next to `TemperatureUnit` inside the class, or right above the `AppSettings` declaration):

```swift
enum CPUDisplayMode: String, CaseIterable, Identifiable {
    case raw1600 = "raw"           // 0–1600 (each core 100%)
    case normalized100 = "normalized"  // 0–100 (Windows-familiar)
    var id: String { rawValue }
}
```

Inside the `AppSettings` class, after `launchAtLogin`, add:

```swift
@Published var processMonitoringEnabled: Bool {
    didSet { UserDefaults.standard.set(processMonitoringEnabled, forKey: "processMonitoringEnabled") }
}
@Published var remediationEnabled: Bool {
    didSet { UserDefaults.standard.set(remediationEnabled, forKey: "remediationEnabled") }
}
@Published var cpuDisplayMode: CPUDisplayMode {
    didSet { UserDefaults.standard.set(cpuDisplayMode.rawValue, forKey: "cpuDisplayMode") }
}
```

- [ ] **Step 3: Initialize them in `init()`**

In `AppSettings.init()`, after `self.launchAtLogin = false`, add:

```swift
self.processMonitoringEnabled = (UserDefaults.standard.object(forKey: "processMonitoringEnabled") as? Bool) ?? true
self.remediationEnabled = (UserDefaults.standard.object(forKey: "remediationEnabled") as? Bool) ?? false
self.cpuDisplayMode = CPUDisplayMode(rawValue:
    UserDefaults.standard.string(forKey: "cpuDisplayMode") ?? "normalized") ?? .normalized100
```

- [ ] **Step 4: Build**

Run: `xcodegen generate && xcodebuild -project "Tom's Fans.xcodeproj" -scheme "Tom's Fans" -configuration Debug build`
Expected: clean build.

- [ ] **Step 5: Commit**

```bash
git add App/Models/AppSettings.swift App/Services/ErrorLog.swift
git commit -m "Add task-manager settings flags and process error source"
```

---

## Task 3: `ProcessSample` model + `ProcessSampler` pure helpers + debug harness

**Files:**
- Create: `App/Models/ProcessSample.swift`
- Create: `App/Services/ProcessSampler.swift`
- Create: `App/Debug/ProcessMonitorDebugHarness.swift`

**Why:** Rate computation and sanity checks are pure functions — easiest to verify in isolation before plugging into a live tick. Debug harness runs them against fixtures at `#if DEBUG` startup.

- [ ] **Step 1: Create `ProcessSample.swift`**

```swift
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
```

- [ ] **Step 2: Create `ProcessSampler.swift` with pure helpers**

```swift
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
        // ri_user_time + ri_system_time are absolute nanoseconds.
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
        var buf = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
        let written = proc_pidpath(pid, &buf, UInt32(buf.count))
        if written > 0 { return String(cString: buf) }
        return ""
    }

    /// Whole-machine CPU usage in percent (0–100), via host_processor_info.
    /// Used as ground truth to cross-check the sum of visible per-PID usage (§6 degraded mode).
    /// Returns nil on Mach call failure.
    static func hostCPUPercent(prev: HostCPUSnapshot?, curr: inout HostCPUSnapshot?) -> Double? {
        var count = mach_msg_type_number_t(HOST_CPU_LOAD_INFO_COUNT)
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
        guard let prev else { return nil }   // need two samples
        let userΔ = Double(snapshot.user - prev.user)
        let sysΔ  = Double(snapshot.system - prev.system)
        let niceΔ = Double(snapshot.nice - prev.nice)
        let idleΔ = Double(snapshot.idle - prev.idle)
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
```

- [ ] **Step 3: Create the debug harness**

`App/Debug/ProcessMonitorDebugHarness.swift`:

```swift
#if DEBUG
import Foundation

/// Fixture-driven sanity checks for ProcessSampler pure functions.
/// Called once during bootstrap in DEBUG builds; prints PASS/FAIL to console.
enum ProcessMonitorDebugHarness {

    static func run() {
        print("=== ProcessMonitor debug harness ===")
        testRateComputation()
        testLivePIDListing()
        print("=== harness done ===")
    }

    private static func testRateComputation() {
        let now = Date()
        // 1 second wall, 0.5 CPU-seconds consumed → 50% raw on a 16-core box → 3.125% normalized.
        let (raw, norm) = ProcessSampler.computeRate(
            prevCPUSeconds: 10.0,
            currCPUSeconds: 10.5,
            prevWall: now,
            currWall: now.addingTimeInterval(1.0),
            logicalCores: 16
        )
        assertClose("rate raw (0.5s/1s, 16c)", raw, 50.0)
        assertClose("rate normalized (0.5s/1s, 16c)", norm, 3.125)

        // Saturated single core: 1 CPU-second over 1 wall-second → 100% raw, 6.25% normalized (on 16c).
        let (raw2, norm2) = ProcessSampler.computeRate(
            prevCPUSeconds: 0, currCPUSeconds: 1.0,
            prevWall: now, currWall: now.addingTimeInterval(1.0),
            logicalCores: 16
        )
        assertClose("rate raw (saturated core)", raw2, 100.0)
        assertClose("rate normalized (saturated core)", norm2, 6.25)

        // Negative CPU delta (process restart / counter wrap) → 0, 0.
        let (raw3, norm3) = ProcessSampler.computeRate(
            prevCPUSeconds: 5.0, currCPUSeconds: 1.0,
            prevWall: now, currWall: now.addingTimeInterval(1.0),
            logicalCores: 16
        )
        assertClose("rate raw (negative delta)", raw3, 0.0)
        assertClose("rate normalized (negative delta)", norm3, 0.0)

        // Zero wall delta → 0, 0.
        let (raw4, _) = ProcessSampler.computeRate(
            prevCPUSeconds: 0, currCPUSeconds: 1.0,
            prevWall: now, currWall: now,
            logicalCores: 16
        )
        assertClose("rate raw (zero wall delta)", raw4, 0.0)
    }

    private static func testLivePIDListing() {
        let pids = ProcessSampler.listAllPIDs()
        let pass = pids.count > 50
        print("\(pass ? "PASS" : "FAIL") listAllPIDs (got \(pids.count), expected > 50)")
        if pass, let firstPID = pids.first {
            let name = ProcessSampler.name(for: firstPID)
            let path = ProcessSampler.path(for: firstPID)
            print("       sample pid=\(firstPID) name=\(name) path=\(path)")
        }
    }

    private static func assertClose(_ label: String, _ a: Double, _ b: Double, tol: Double = 0.001) {
        let pass = abs(a - b) <= tol
        print("\(pass ? "PASS" : "FAIL") \(label): got \(a), expected \(b)")
    }
}
#endif
```

- [ ] **Step 4: Wire the harness into bootstrap**

In `App/TomsFansApp.swift`, in `bootstrapIfNeeded()`, after the last existing line (`observeSleepWake()`), add:

```swift
#if DEBUG
ProcessMonitorDebugHarness.run()
#endif
```

- [ ] **Step 5: Build, run the app once, observe console output**

Run: `xcodegen generate && xcodebuild -project "Tom's Fans.xcodeproj" -scheme "Tom's Fans" -configuration Debug build`
Then launch from Xcode and read the Run console. Expected: all four `testRateComputation` lines say `PASS`, and `testLivePIDListing` says `PASS (got NNN, expected > 50)` where NNN is the real PID count.

If any FAIL: the pure function is broken — fix before moving on.

- [ ] **Step 6: Commit**

```bash
git add App/Models/ProcessSample.swift App/Services/ProcessSampler.swift App/Debug/ProcessMonitorDebugHarness.swift App/TomsFansApp.swift
git commit -m "Add ProcessSample model, ProcessSampler helpers, debug harness"
```

---

## Task 4: `ProcessMonitorService` — sampling each tick (no UI yet)

**Files:**
- Create: `App/Services/ProcessMonitorService.swift`
- Modify: `App/TomsFansApp.swift`

- [ ] **Step 1: Create the service skeleton**

`App/Services/ProcessMonitorService.swift`:

```swift
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
        if !on {
            // Drop history when leaving foreground; lightweight background sampling continues.
            // (Ring buffer added in Task 5 — clearing it goes here once added.)
        }
    }

    /// Called on every tick from monitor.onPollAlways.
    func sample() {
        let now = Date()
        let allPIDs = ProcessSampler.listAllPIDs()

        // Build samples for every PID we can read.
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
                (raw, normalized) = (0, 0)   // first tick for this PID — no rate yet
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

        // Drop entries for PIDs we no longer see.
        let visibleSet = Set(allPIDs)
        prevCPUSeconds = prevCPUSeconds.filter { visibleSet.contains($0.key) }

        // Sort by raw% desc.
        newSamples.sort { $0.cpuRawPct > $1.cpuRawPct }

        // Background mode keeps only the top N.
        let trimmed = foregroundMode ? newSamples : Array(newSamples.prefix(backgroundTopN))

        // Host CPU% cross-check.
        var newSnapshot: HostCPUSnapshot? = nil
        let hostPct = ProcessSampler.hostCPUPercent(prev: prevHostSnapshot, curr: &newSnapshot) ?? 0
        prevHostSnapshot = newSnapshot

        DispatchQueue.main.async {
            self.samples = trimmed
            self.hostCPUPercent = hostPct
        }
    }
}
```

- [ ] **Step 2: Wire it into `TomsFansApp`**

In `App/TomsFansApp.swift`:

(a) Add the `@StateObject` next to the existing ones:

```swift
@StateObject private var processMonitor = ProcessMonitorService()
```

(b) Pass it as an environment object to `ContentView` (alongside the existing ones):

```swift
.environmentObject(processMonitor)
```

(c) In `bootstrapIfNeeded()`, after `curveEngine.errorLog = errorLog`, add:

```swift
processMonitor.errorLog = errorLog
```

(d) Set up the always-fires callback. After `setupPollCallback()` is called in `bootstrapIfNeeded()`, add:

```swift
setupProcessSamplingCallback()
```

Add the new method after `setupPollCallback()`:

```swift
private func setupProcessSamplingCallback() {
    monitor.onPollAlways = { [weak processMonitor, weak settings] in
        guard settings?.processMonitoringEnabled == true else { return }
        processMonitor?.sample()
    }
}
```

- [ ] **Step 3: Build and run the app**

Run: `xcodegen generate && xcodebuild -project "Tom's Fans.xcodeproj" -scheme "Tom's Fans" -configuration Debug build`
Launch from Xcode. Expected: clean build, no crashes, no console errors. (No UI changes yet — verifying the service runs without exploding.)

- [ ] **Step 4: Add a temporary print to confirm sampling**

Inside `ProcessMonitorService.sample()`, just before the `DispatchQueue.main.async` block, add a temporary diagnostic:

```swift
#if DEBUG
if Int.random(in: 0..<5) == 0 {   // ~1 in 5 ticks to avoid log spam
    let top = trimmed.prefix(3).map { "\($0.name)=\(Int($0.cpuRawPct))%" }.joined(separator: " ")
    print("[ProcMon] \(trimmed.count) procs, host=\(Int(hostPct))%, top: \(top)")
}
#endif
```

Run the app, watch console for ~10 seconds. Expected: lines like `[ProcMon] 312 procs, host=4%, top: WindowServer=12% kernel_task=8% Xcode=5%`.

- [ ] **Step 5: Remove the temporary print, commit**

Remove the `#if DEBUG` block from Step 4.

```bash
git add App/Services/ProcessMonitorService.swift App/TomsFansApp.swift
git commit -m "Add ProcessMonitorService with per-tick sampling"
```

---

## Task 5: Foreground/background mode + 60-second ring buffer

**Files:**
- Modify: `App/Services/ProcessMonitorService.swift`
- Modify: `App/TomsFansApp.swift`

- [ ] **Step 1: Add the ring buffer + per-PID history**

In `ProcessMonitorService.swift`, near the other private state, add:

```swift
/// Per-PID rolling history of (sample, when). Only populated in foreground mode.
/// Pruned to 60s on each insert.
private var ringBuffer: [pid_t: [ProcessSample]] = [:]
private let ringBufferDuration: TimeInterval = 60
```

- [ ] **Step 2: Append to the ring buffer in foreground mode**

In `sample()`, immediately before the `DispatchQueue.main.async` block, add:

```swift
if foregroundMode {
    let cutoff = now.addingTimeInterval(-ringBufferDuration)
    for s in newSamples {
        var hist = ringBuffer[s.pid] ?? []
        hist.append(s)
        // Prune anything older than cutoff.
        if let firstKeep = hist.firstIndex(where: { $0.sampledAt >= cutoff }), firstKeep > 0 {
            hist.removeFirst(firstKeep)
        }
        ringBuffer[s.pid] = hist
    }
    // Drop history for PIDs that disappeared.
    ringBuffer = ringBuffer.filter { visibleSet.contains($0.key) }
}
```

- [ ] **Step 3: Clear the ring buffer when leaving foreground**

Replace the empty body in `setForegroundMode`:

```swift
func setForegroundMode(_ on: Bool) {
    foregroundMode = on
    if !on {
        ringBuffer.removeAll()
    }
}
```

- [ ] **Step 4: Expose read access for the correlator (added next task)**

Add a method to `ProcessMonitorService`:

```swift
/// Snapshot of a PID's recent samples (oldest → newest) within the 60s window.
/// Empty if foreground mode is off or the PID has no history.
func recentHistory(for pid: pid_t) -> [ProcessSample] {
    return ringBuffer[pid] ?? []
}
```

- [ ] **Step 5: Wire foreground/background switching to window lifecycle**

In `App/TomsFansApp.swift`, find the `.onAppear` and `.onDisappear` blocks on the main Window's `ContentView`. Add the foreground toggle:

`.onAppear` block — after `monitor.setIdleMode(false)`:
```swift
processMonitor.setForegroundMode(true)
```

`.onDisappear` block — after `monitor.setIdleMode(true)`:
```swift
processMonitor.setForegroundMode(false)
```

- [ ] **Step 6: Build and run**

Run: `xcodegen generate && xcodebuild -project "Tom's Fans.xcodeproj" -scheme "Tom's Fans" -configuration Debug build`
Launch. Expected: clean build, no crashes. (No visible change yet — verifying foreground toggle wires up cleanly.)

- [ ] **Step 7: Commit**

```bash
git add App/Services/ProcessMonitorService.swift App/TomsFansApp.swift
git commit -m "Add foreground ring buffer for ProcessMonitorService"
```

---

## Task 6: Process list UI + Activity Monitor cross-check

**Files:**
- Create: `App/Views/Components/ProcessListView.swift`
- Modify: `App/Views/Main/DashboardView.swift`

- [ ] **Step 1: Create `ProcessListView.swift`**

```swift
import SwiftUI

struct ProcessListView: View {
    let samples: [ProcessSample]
    let hostCPUPercent: Double
    @Binding var displayMode: CPUDisplayMode

    var body: some View {
        GroupBox("Processes") {
            VStack(alignment: .leading, spacing: 8) {
                header
                Divider()
                rows
                Divider()
                footer
            }
            .padding(.vertical, 4)
        }
    }

    private var header: some View {
        HStack {
            Picker("Display", selection: $displayMode) {
                Text("0–100%").tag(CPUDisplayMode.normalized100)
                Text("0–\(ProcessSampler.logicalCoreCount * 100)%").tag(CPUDisplayMode.raw1600)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            Spacer()

            Text("System: \(Int(hostCPUPercent))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Process").frame(maxWidth: .infinity, alignment: .leading)
                Text("PID").frame(width: 60, alignment: .trailing)
                Text("CPU%").frame(width: 70, alignment: .trailing)
                Text("Mem").frame(width: 80, alignment: .trailing)
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.bottom, 2)

            ForEach(samples.prefix(20)) { sample in
                HStack {
                    Text(sample.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(sample.pid)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    Text(cpuLabel(sample))
                        .font(.caption.monospacedDigit())
                        .frame(width: 70, alignment: .trailing)
                    Text(memoryLabel(sample.rssBytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
        }
    }

    private var footer: some View {
        Text("Showing top \(min(samples.count, 20)) of \(samples.count)")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func cpuLabel(_ s: ProcessSample) -> String {
        let value = displayMode == .raw1600 ? s.cpuRawPct : s.cpuNormalizedPct
        return String(format: "%.1f", value)
    }

    private func memoryLabel(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }
}
```

- [ ] **Step 2: Wire `ProcessListView` into `DashboardView`**

In `App/Views/Main/DashboardView.swift`, add to the `@EnvironmentObject` declarations of `DashboardView`:

```swift
@EnvironmentObject var processMonitor: ProcessMonitorService
```

In the `mainPanel` `LazyVStack`, after the existing `if settings.controlMode == .fanCurve, !settings.fanCurves.isEmpty { fanCurveSection }` line, add:

```swift
if settings.processMonitoringEnabled {
    ProcessListView(
        samples: processMonitor.samples,
        hostCPUPercent: processMonitor.hostCPUPercent,
        displayMode: Binding(
            get: { settings.cpuDisplayMode },
            set: { settings.cpuDisplayMode = $0 }
        )
    )
}
```

- [ ] **Step 3: Build, launch, cross-check against Activity Monitor**

Run: `xcodegen generate && xcodebuild -project "Tom's Fans.xcodeproj" -scheme "Tom's Fans" -configuration Debug build`
Launch. Open the dashboard. Expected: a "Processes" section appears with a sorted list.

Now generate known load and compare to Activity Monitor (in another terminal):
```bash
yes > /dev/null & yes > /dev/null & yes > /dev/null & yes > /dev/null &
```

Open Activity Monitor → CPU tab. Find the `yes` processes. Compare their CPU% to what Tom's Fans shows.

Acceptance:
- In raw mode (0–1600%): each `yes` process should show ~100% in both.
- In normalized mode (0–100%): each should show ~`100/16` ≈ 6.25%.
- Within ~5% of Activity Monitor's number is acceptable.

Kill the `yes` processes when done:
```bash
killall yes
```

If numbers are wildly off (> 10% drift): fix `computeRate` or `cpuTimeSeconds(for:)` before continuing.

- [ ] **Step 4: Commit**

```bash
git add App/Views/Components/ProcessListView.swift App/Views/Main/DashboardView.swift
git commit -m "Add process list view with Activity Monitor parity"
```

---

## Task 7: `ProcessCulprit` model + `ThermalCorrelator`

**Files:**
- Create: `App/Models/ProcessCulprit.swift`
- Create: `App/Services/ThermalCorrelator.swift`
- Modify: `App/Services/ProcessMonitorService.swift`

- [ ] **Step 1: Create `ProcessCulprit.swift`**

```swift
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
```

- [ ] **Step 2: Create `ThermalCorrelator.swift`**

```swift
import Foundation

final class ThermalCorrelator {
    /// PIDs/names never offered as culprits or remediation targets.
    static let neverRankNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow",
        "logd", "mds", "mds_stores", "com.tomsfans.helper",
        "Tom's Fans"
    ]
    /// A PID counts as "the culprit" when its raw% exceeds this for the required tick count.
    static let candidateRawPctThreshold: Double = 840    // ≈70% of 16-thread machine
    static let candidateConsecutiveTicks = 3
    /// `kernel_task` showing more than this raw% means macOS is in cooling mode.
    static let kernelTaskCoolingThreshold: Double = 200

    /// Tracks how many consecutive ticks each PID has been above threshold.
    private var streakCount: [pid_t: Int] = [:]

    /// Evaluate one tick. Returns the current culprit state (or nil if everything's calm).
    func evaluate(samples: [ProcessSample], thermalState: ProcessInfo.ThermalState) -> ProcessCulprit? {
        // Update streaks for every visible PID.
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

        // Trigger condition: either thermalState ≥ serious, or any PID streaked enough.
        let thermalTrigger = thermalState == .serious || thermalState == .critical
        let streakTrigger = streakCount.values.contains { $0 >= Self.candidateConsecutiveTicks }
        guard thermalTrigger || streakTrigger else { return nil }

        // kernel_task cooling special case.
        if let kt = samples.first(where: { $0.name == "kernel_task" }),
           kt.cpuRawPct > Self.kernelTaskCoolingThreshold {
            return .macOSCooling
        }

        // Pick the candidate with the longest streak (tie-break by raw%).
        let streakedPIDs = streakCount.filter { $0.value >= Self.candidateConsecutiveTicks }.keys
        let candidates = samples
            .filter { streakedPIDs.contains($0.pid) && !Self.neverRankNames.contains($0.name) }
            .sorted { ($0.cpuRawPct) > ($1.cpuRawPct) }

        if let top = candidates.first {
            return .candidate(pid: top.pid, name: top.name, sustainedRawPct: top.cpuRawPct)
        }

        // Triggered but nothing visible — likely GPU/IO.
        return .noCPUSource
    }

    func reset() {
        streakCount.removeAll()
    }
}
```

- [ ] **Step 3: Plug correlator into `ProcessMonitorService`**

In `ProcessMonitorService.swift`:

(a) Add a stored property near `prevHostSnapshot`:

```swift
private let correlator = ThermalCorrelator()
@Published private(set) var culprit: ProcessCulprit?
```

(b) Subscribe to `thermalStateDidChangeNotification` so we always know the current state. Add an initializer:

```swift
init() {
    NotificationCenter.default.addObserver(
        forName: ProcessInfo.thermalStateDidChangeNotification,
        object: nil, queue: .main
    ) { [weak self] _ in
        self?.lastThermalState = ProcessInfo.processInfo.thermalState
    }
    lastThermalState = ProcessInfo.processInfo.thermalState
}
private var lastThermalState: ProcessInfo.ThermalState = .nominal
```

(c) At the end of `sample()`, after the `DispatchQueue.main.async` block, add **inside** that same async block (so it runs on main with the new samples):

Edit the existing `DispatchQueue.main.async` to look like:

```swift
DispatchQueue.main.async {
    self.samples = trimmed
    self.hostCPUPercent = hostPct
    self.culprit = self.correlator.evaluate(samples: trimmed, thermalState: self.lastThermalState)
}
```

- [ ] **Step 4: Add a quick console diagnostic to verify culprit detection**

Temporarily, in `ProcessMonitorService.sample()`, after the line that sets `self.culprit = ...`, add:

```swift
#if DEBUG
if let c = self.culprit {
    print("[Culprit] \(c)")
}
#endif
```

- [ ] **Step 5: Build, run, generate heavy load to trigger detection**

```bash
yes > /dev/null & yes > /dev/null & yes > /dev/null & yes > /dev/null &
yes > /dev/null & yes > /dev/null & yes > /dev/null & yes > /dev/null &
```

(8 instances, each saturating a core → 800% raw → should trip one of them as a candidate after 3 ticks.)

Watch console. Expected: within ~5 seconds, a `[Culprit] candidate(pid: ..., name: "yes", sustainedRawPct: ~100)` line appears.

Wait — but a single `yes` process only hits ~100% raw, well under our 840% threshold. We need ONE process above 840%. Adjust the test:

```bash
killall yes
# Run a CPU-burner that uses multiple cores in one process. macOS doesn't ship one,
# so use `stress-ng` if installed (`brew install stress-ng`), or a small Swift one-liner:
swift -e 'DispatchQueue.concurrentPerform(iterations: 12) { _ in while true {} }' &
```

That single `swift` PID will sustain ~1200% raw → above 840 → should trip `candidate(pid: ..., name: "swift", ...)`.

Kill it when done:
```bash
killall swift
```

Acceptance: `[Culprit] candidate(...)` printed within ~5s; `[Culprit] nil` (or no print) when load gone.

- [ ] **Step 6: Remove the debug print, commit**

Remove the `#if DEBUG` block from Step 4.

```bash
git add App/Models/ProcessCulprit.swift App/Services/ThermalCorrelator.swift App/Services/ProcessMonitorService.swift
git commit -m "Add ThermalCorrelator with culprit detection"
```

---

## Task 8: Degraded-mode detection

**Files:**
- Modify: `App/Services/ProcessMonitorService.swift`

- [ ] **Step 1: Add degraded-state tracking**

In `ProcessMonitorService.swift`, near the other private state:

```swift
/// Consecutive ticks where sample data looked untrustworthy.
private var degradedStreak = 0
private static let degradedTickThreshold = 3
private static let pidCountFloor = 20
/// If sum-of-visible-CPU is more than this many points below host CPU%, treat as blind.
private static let cpuGapPctThreshold: Double = 50

/// Tracked separately so we can log only on entry.
private var inDegradedMode = false
```

- [ ] **Step 2: Compute degraded state each tick**

In `sample()`, after `newSamples.sort { $0.cpuRawPct > $1.cpuRawPct }` but **before** `let trimmed = ...`, add:

```swift
// §6 degraded-mode detection — runs against the full (untrimmed) sample set.
let visibleCPUSum = newSamples.reduce(0.0) { $0 + $1.cpuRawPct }
// Compare against host% scaled to the same 0–1600 raw range:
let hostCPURaw = hostPct * Double(ProcessSampler.logicalCoreCount)  // host is 0–100, raw is 0–(100×cores)
let gap = max(0, hostCPURaw - visibleCPUSum)

let tooFewPIDs = allPIDs.count < Self.pidCountFloor
let widenedGap = gap > (Self.cpuGapPctThreshold * Double(ProcessSampler.logicalCoreCount))

let degradedThisTick = tooFewPIDs || widenedGap
let reasonString: String? = tooFewPIDs
    ? "process enumeration returned only \(allPIDs.count) PIDs"
    : (widenedGap ? "visible CPU sum below host total by \(Int(gap / Double(ProcessSampler.logicalCoreCount)))%" : nil)

if degradedThisTick {
    degradedStreak += 1
} else {
    degradedStreak = 0
}
```

Note: above uses `hostPct`, but `hostPct` is currently computed *after* this block. Move the host-CPU computation higher in the method — specifically, move the lines starting `var newSnapshot: HostCPUSnapshot? = nil` and ending with `prevHostSnapshot = newSnapshot` to **right before** the degraded-state block.

- [ ] **Step 3: Override culprit when degraded**

Inside the existing `DispatchQueue.main.async` block, replace:

```swift
self.culprit = self.correlator.evaluate(samples: trimmed, thermalState: self.lastThermalState)
```

with:

```swift
if self.degradedStreak >= Self.degradedTickThreshold {
    if !self.inDegradedMode {
        self.inDegradedMode = true
        self.errorLog?.logTransient(
            "Process monitoring degraded — \(reasonString ?? "unknown reason")",
            source: .process
        )
    }
    self.correlator.reset()
    self.culprit = .degraded(reason: reasonString ?? "untrusted sample")
} else {
    if self.inDegradedMode {
        self.inDegradedMode = false
    }
    self.culprit = self.correlator.evaluate(samples: trimmed, thermalState: self.lastThermalState)
}
```

- [ ] **Step 4: Build and run**

```bash
xcodegen generate && xcodebuild -project "Tom's Fans.xcodeproj" -scheme "Tom's Fans" -configuration Debug build
```

Launch from Xcode. Expected: clean build. The PID count will be well above 20 on a real machine, so degraded mode should never fire in normal use — `culprit` should never be `.degraded`. (We have no easy way to artificially trip it without mocking; trust the logic and move on. The behavior gets exercised by the UI test in Task 14.)

- [ ] **Step 5: Commit**

```bash
git add App/Services/ProcessMonitorService.swift
git commit -m "Add degraded-mode detection to ProcessMonitorService"
```

---

## Task 9: XPC helper protocol extension + helper-side `sendSignal`

**Files:**
- Modify: `Shared/XPCProtocol/FanControlProtocol.swift`
- Modify: `Helper/FanControlServiceImpl.swift`

- [ ] **Step 1: Add `sendSignal` to the protocol**

In `Shared/XPCProtocol/FanControlProtocol.swift`, add to the protocol body (after `getHelperVersion`):

```swift
/// Send a POSIX signal (SIGTERM, SIGKILL, SIGSTOP, SIGCONT only) to a PID.
/// The helper validates the PID server-side against the never-signal list.
/// Reply: (success, error message or nil).
func sendSignal(_ signal: Int32, toPID pid: pid_t,
                withReply reply: @escaping (Bool, String?) -> Void)
```

- [ ] **Step 2: Implement `sendSignal` on the helper**

In `Helper/FanControlServiceImpl.swift`, add a private constant near the top of the class (after `private var originalModes`):

```swift
/// Process names the helper will never signal, regardless of what the client asks for.
private static let neverSignalNames: Set<String> = [
    "kernel_task", "launchd", "WindowServer", "loginwindow",
    "logd", "mds", "mds_stores", "com.tomsfans.helper", "Tom's Fans"
]
private static let allowedSignals: Set<Int32> = [SIGTERM, SIGKILL, SIGSTOP, SIGCONT]
```

Add the method implementation alongside the other protocol methods:

```swift
func sendSignal(_ signal: Int32, toPID pid: pid_t,
                withReply reply: @escaping (Bool, String?) -> Void) {
    // 1. Allowed signals only.
    guard Self.allowedSignals.contains(signal) else {
        reply(false, "signal \(signal) not allowed")
        return
    }
    // 2. Never-signal PIDs.
    guard pid > 1 else {
        reply(false, "PID \(pid) is protected (kernel/launchd)")
        return
    }
    if pid == getpid() {
        reply(false, "refused to signal helper itself")
        return
    }
    // 3. Never-signal names.
    var nameBuf = [CChar](repeating: 0, count: 1024)
    let written = proc_name(pid, &nameBuf, UInt32(nameBuf.count))
    if written > 0 {
        let name = String(cString: nameBuf)
        if Self.neverSignalNames.contains(name) {
            reply(false, "process \(name) is on the never-signal list")
            return
        }
    }
    // 4. Send it.
    let result = kill(pid, signal)
    if result == 0 {
        reply(true, nil)
    } else {
        reply(false, "kill(\(pid), \(signal)) failed: errno=\(errno)")
    }
}
```

The helper also needs `import Darwin` for `kill`, `getpid`, `proc_name`, and the signal constants. Add at the top if not already present:

```swift
import Darwin
```

- [ ] **Step 3: Bump the helper version**

In `Shared/XPCProtocol/XPCConstants.swift`, find the `helperVersion` string constant and increment its patch number (e.g. `"1.0.1"` → `"1.0.2"`). If you can't find a version constant, skip this step — the helper will redeploy on next launch anyway via SMAppService.

- [ ] **Step 4: Build both targets**

```bash
xcodegen generate && xcodebuild -project "Tom's Fans.xcodeproj" -scheme "Tom's Fans" -configuration Debug build
```

Expected: clean build. The helper's `FanControlServiceImpl` now conforms to the extended protocol.

- [ ] **Step 5: Commit**

```bash
git add Shared/XPCProtocol/FanControlProtocol.swift Helper/FanControlServiceImpl.swift Shared/XPCProtocol/XPCConstants.swift
git commit -m "Add sendSignal to XPC protocol with helper-side validation"
```

---

## Task 10: `XPCFanControlService.sendSignal` client wrapper + `ProcessRemediationService.terminate`

**Files:**
- Modify: `App/Services/XPCFanControlService.swift`
- Create: `App/Services/ProcessRemediationService.swift`
- Modify: `App/TomsFansApp.swift`

- [ ] **Step 1: Add convenience wrapper on `XPCFanControlService`**

In `App/Services/XPCFanControlService.swift`, add this method alongside the other convenience methods (e.g. after `restoreAutomatic`):

```swift
/// Send a POSIX signal to a PID via the helper.
/// `completion` runs on the main queue with (success, optional error message).
func sendSignal(_ signal: Int32, toPID pid: pid_t,
                completion: @escaping (Bool, String?) -> Void) {
    proxy?.sendSignal(signal, toPID: pid) { [weak self] success, error in
        DispatchQueue.main.async {
            if !success, let error {
                self?.errorLog?.logTransient(error, source: .xpc)
            }
            completion(success, error)
        }
    }
}
```

- [ ] **Step 2: Create `ProcessRemediationService.swift` with `terminate` only**

```swift
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
            // After 3s, escalate to SIGKILL if still alive.
            self?.queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                if kill(pid, 0) == 0 {
                    // Process still alive — escalate.
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
```

- [ ] **Step 3: Wire it into `TomsFansApp`**

In `App/TomsFansApp.swift`:

(a) Add the `@StateObject`:
```swift
@StateObject private var remediation = ProcessRemediationService()
```

(b) Add `.environmentObject(remediation)` to `ContentView` (in the main Window scene).

(c) In `bootstrapIfNeeded()`, after `processMonitor.errorLog = errorLog`, add:

```swift
remediation.errorLog = errorLog
remediation.xpc = fanControl
```

- [ ] **Step 4: Manual smoke test of terminate**

Build and launch. Open Xcode console. In a separate terminal:

```bash
yes > /dev/null &
echo "test PID: $!"
```

Note the PID. In the running app, temporarily add a button to the dashboard, OR call from a debugger. The simplest verification: open `DashboardView.swift` and just before `ProcessListView(...)`, temporarily add (only for this manual test):

```swift
#if DEBUG
Button("DEBUG: Terminate top process") {
    if let top = processMonitor.samples.first(where: { $0.name == "yes" }) {
        remediation.terminate(pid: top.pid, name: top.name)
    }
}
#endif
```

(Don't forget: `@EnvironmentObject var remediation: ProcessRemediationService` needs to be added to the DashboardView, behind `#if DEBUG` is fine.)

Click the button. The `yes` process should die within ~3s (will be visible disappearing from Activity Monitor).

**Acceptance:** the `yes` PID disappears.

- [ ] **Step 5: Remove the debug button, keep the code path**

Remove the `#if DEBUG ... #endif` block from `DashboardView.swift` you added in Step 4. (The real button will be added in Task 14.) Keep the `@EnvironmentObject var remediation: ProcessRemediationService` declaration — it'll be reused next.

- [ ] **Step 6: Commit**

```bash
git add App/Services/XPCFanControlService.swift App/Services/ProcessRemediationService.swift App/TomsFansApp.swift App/Views/Main/DashboardView.swift
git commit -m "Add ProcessRemediationService terminate/forceQuit actions"
```

---

## Task 11: `throttle` action with bounded SIGSTOP/CONT + the three resume triggers

**Files:**
- Modify: `App/Services/ProcessRemediationService.swift`

- [ ] **Step 1: Add the `Suspension` struct and `suspendedPIDs` map**

In `ProcessRemediationService.swift`, add inside the class above the existing `terminate` method:

```swift
private struct Suspension {
    let pid: pid_t
    let name: String
    let suspendedAt: Date
    let tempsAtSuspend: [String: Double]   // sensor key → °C at suspend time
    var resumeWorkItem: DispatchWorkItem?
}
private var suspendedPIDs: [pid_t: Suspension] = [:]
private let maxSuspensionSeconds: TimeInterval = 10
private let earlyResumeTempDropC: Double = 5
```

- [ ] **Step 2: Implement `throttle`**

Add this method alongside `terminate`:

```swift
func throttle(pid: pid_t, name: String, currentTemps: [String: Double]) {
    guard let xpc else {
        errorLog?.logTransient("Cannot throttle \(name) — helper not connected", source: .process)
        return
    }
    // Refuse to double-throttle the same PID.
    if suspendedPIDs[pid] != nil { return }

    xpc.sendSignal(SIGSTOP, toPID: pid) { [weak self] success, _ in
        guard success, let self else { return }

        // Schedule the hard-deadline resume (10s).
        let resumeWork = DispatchWorkItem { [weak self] in
            self?.resume(pid: pid)
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
```

- [ ] **Step 3: Implement the single mutation point `resume(pid:)`**

Add as a private method on the class:

```swift
/// Single mutation point: cancels the deadline, sends SIGCONT, removes from the map.
/// Always all three or none. Safe to call multiple times for the same PID (idempotent).
private func resume(pid: pid_t) {
    guard let suspension = suspendedPIDs.removeValue(forKey: pid) else { return }
    suspension.resumeWorkItem?.cancel()
    // Prefer XPC path; fall back to direct kill() if helper is gone (SIGCONT is harmless to a running process).
    if let xpc, xpc.isConnected {
        xpc.sendSignal(SIGCONT, toPID: pid) { _, _ in }
    } else {
        _ = kill(pid, SIGCONT)
    }
}
```

- [ ] **Step 4: Implement `onTempUpdate` (early-resume trigger #2)**

Add as a public method on the class:

```swift
/// Called each tick with current temperatures. Resumes any PID whose suspend-time
/// temperature snapshot has dropped by `earlyResumeTempDropC` on any tracked sensor.
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
```

- [ ] **Step 5: Implement `resumeAllSuspended` (safety net / trigger #3)**

Add as a public method on the class:

```swift
/// Synchronously resumes every suspended PID. Wired into all teardown paths
/// (sleep, helper disconnect, safety restore, app quit, deinit).
/// Falls back to direct kill() if XPC is unreachable.
func resumeAllSuspended() {
    let pids = Array(suspendedPIDs.keys)
    for pid in pids { resume(pid: pid) }
}

deinit {
    resumeAllSuspended()
}
```

- [ ] **Step 6: Build**

```bash
xcodegen generate && xcodebuild -project "Tom's Fans.xcodeproj" -scheme "Tom's Fans" -configuration Debug build
```

Expected: clean build. (Manual end-to-end test deferred to Task 13 after all wire-ups are in.)

- [ ] **Step 7: Commit**

```bash
git add App/Services/ProcessRemediationService.swift
git commit -m "Add bounded SIGSTOP throttle with three resume triggers"
```

---

## Task 12: Wire `resumeAllSuspended` into every teardown path

**Files:**
- Modify: `App/TomsFansApp.swift`

- [ ] **Step 1: Extend the shared `restore` closure (safety-restore + helper disconnect path)**

In `App/TomsFansApp.swift`, find `setupSafetyCallbacks()`. Modify the `restore` closure to call `resumeAllSuspended` **first** (before the existing fan-restore logic):

Replace:

```swift
let restore = { [weak fanControl, weak curveEngine, weak settings] in
    guard let settings, let fanControl else { return }
    guard settings.controlMode != .automatic else { return }
    settings.controlMode = .automatic
    curveEngine?.reset()
    fanControl.restoreAutomatic()
}
```

with:

```swift
let restore = { [weak fanControl, weak curveEngine, weak settings, weak remediation] in
    // Resume any suspended PIDs FIRST — must happen even if fan restore fails.
    remediation?.resumeAllSuspended()

    guard let settings, let fanControl else { return }
    guard settings.controlMode != .automatic else { return }
    settings.controlMode = .automatic
    curveEngine?.reset()
    fanControl.restoreAutomatic()
}
```

- [ ] **Step 2: Hook the early-resume temp watcher into the poll**

Still in `TomsFansApp.swift`, find `setupPollCallback()`. Modify the closure to also call `remediation.onTempUpdate`:

Inside the existing `monitor.onPoll = { ... temps in ... }`, add `[weak remediation]` to the capture list and call `remediation?.onTempUpdate(...)` at the top of the body (above the existing curve/notification logic):

```swift
private func setupPollCallback() {
    monitor.onPoll = { [weak curveEngine, weak settings, weak fanControl, weak monitor, weak notifications, weak remediation] temps in
        // Build a {key → °C} map for the remediation early-resume check.
        let tempsDict = Dictionary(uniqueKeysWithValues: temps.map { ($0.key, $0.value) })
        remediation?.onTempUpdate(tempsDict)

        guard let settings, let fanControl else { return }
        // ... existing curve + notifications logic, unchanged ...
        if settings.controlMode == .fanCurve {
            let curve = settings.fanCurves.first(where: { $0.id == settings.activeCurveId })
                ?? settings.fanCurves.first
            if let curve {
                if settings.activeCurveId != curve.id {
                    settings.activeCurveId = curve.id
                }
                curveEngine?.evaluate(curve: curve, temperatures: temps,
                                      fans: monitor?.fans ?? [], fanControl: fanControl)
            }
        }

        notifications?.checkThresholds(temperatures: temps, thresholds: settings.alertThresholds)
    }
}
```

- [ ] **Step 3: Hook sleep into resume**

Still in `TomsFansApp.swift`, find `observeSleepWake()`. In the `willSleepNotification` sink block, add `remediation?.resumeAllSuspended()` as the first action. Change:

```swift
center.publisher(for: NSWorkspace.willSleepNotification)
    .sink { [weak fanControl, weak curveEngine, weak monitor] _ in
        fanControl?.restoreAutomatic()
        curveEngine?.reset()
        monitor?.pausePolling()
    }
    .store(in: &Self.cancellables)
```

to:

```swift
center.publisher(for: NSWorkspace.willSleepNotification)
    .sink { [weak fanControl, weak curveEngine, weak monitor, weak remediation] _ in
        remediation?.resumeAllSuspended()
        fanControl?.restoreAutomatic()
        curveEngine?.reset()
        monitor?.pausePolling()
    }
    .store(in: &Self.cancellables)
```

- [ ] **Step 4: Hook applicationWillTerminate**

`AppDelegate.applicationWillTerminate` currently only sets `isTerminating = true`. It needs access to the remediation service to resume PIDs before quitting. Add a static weak reference:

Replace the bottom of `TomsFansApp.swift`:

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var isTerminating = false
    static weak var remediation: ProcessRemediationService?

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.isTerminating = true
        Self.remediation?.resumeAllSuspended()
    }
}
```

Then in `bootstrapIfNeeded()`, after `remediation.xpc = fanControl`, add:

```swift
AppDelegate.remediation = remediation
```

- [ ] **Step 5: Build**

```bash
xcodegen generate && xcodebuild -project "Tom's Fans.xcodeproj" -scheme "Tom's Fans" -configuration Debug build
```

Expected: clean build.

- [ ] **Step 6: Commit**

```bash
git add App/TomsFansApp.swift
git commit -m "Wire resumeAllSuspended into safety/sleep/quit teardown paths"
```

---

## Task 13: Run the manual safety-invariant checklist

**Files:** None (verification step)

Before touching the UI, exercise every teardown path to confirm no PID is ever left in `T` (stopped) state. Each scenario uses a known `yes` PID throttled via a temporary debug button.

- [ ] **Step 1: Add a temporary debug "Throttle top non-system PID" button**

In `App/Views/Main/DashboardView.swift`, just before the `ProcessListView(...)` call inside `mainPanel`, add:

```swift
#if DEBUG
HStack {
    Button("DEBUG: Throttle top non-system process") {
        let candidate = processMonitor.samples.first { s in
            s.cpuRawPct > 10 && !ThermalCorrelator.neverRankNames.contains(s.name)
        }
        if let c = candidate {
            let temps = Dictionary(uniqueKeysWithValues: monitor.temperatures.map { ($0.key, $0.value) })
            remediation.throttle(pid: c.pid, name: c.name, currentTemps: temps)
            print("[DEBUG] throttled \(c.name) pid=\(c.pid)")
        }
    }
}
#endif
```

(Make sure `@EnvironmentObject var remediation: ProcessRemediationService` is on `DashboardView` — added in Task 10.)

Build and launch.

- [ ] **Step 2: Run each scenario from spec §8.1**

For each row below: in a terminal start `yes > /dev/null &`, note its PID, click the debug throttle button, then trigger the test action. Verify in Activity Monitor that the `yes` process is **Running**, not **Stopped**, afterward. (Activity Monitor's State column shows `Running` or `Stopped`.)

Mark each as it passes:

- [ ] **Hard deadline**: throttle, wait 10s. PID should be Running again at ~10s.
- [ ] **Early resume**: throttle, then drop CPU load (kill heavy apps, or just wait — temps drift down). PID should resume early when any sensor temp drops ≥ 5°C from the suspend-time value.
- [ ] **Sleep**: throttle, then `sudo pmset sleepnow` from terminal. Wake the machine; PID should be Running (not Stopped) when you wake.
- [ ] **Helper disconnect**: throttle, then `sudo launchctl kill SIGTERM system/com.tomsfans.helper`. PID should be Running (via the direct `kill()` fallback in `resume`).
- [ ] **App quit**: throttle, then ⌘Q the app. After quit, check Activity Monitor — PID should be Running.
- [ ] **Safety restore**: this requires triggering the existing curve safety condition (e.g. by hitting the SMC failure path). Hard to reproduce without unplugging the SMC. **Skip this scenario** if you can't reproduce; document in the commit message that it's covered by code review since the `restore` closure now calls `resumeAllSuspended()` unconditionally.
- [ ] **App crash (documented gap)**: throttle, then `kill -9` the Tom's Fans app process. PID will stay Stopped. This is the documented v1 gap from spec §5.7. Manually SIGCONT it: `kill -CONT <pid>`. Then `killall yes`.

If any of the first 5 scenarios leave the PID Stopped: a teardown path isn't calling `resumeAllSuspended`. Fix before continuing.

- [ ] **Step 3: Remove the debug throttle button**

Remove the `#if DEBUG` block added in Step 1 from `DashboardView.swift`. (The real button is added in Task 14.)

- [ ] **Step 4: Commit**

```bash
git add App/Views/Main/DashboardView.swift
git commit -m "Remove debug throttle button after safety checklist passed"
```

---

## Task 14: `CulpritCardView` + Force Quit confirm sheet

**Files:**
- Create: `App/Views/Components/CulpritCardView.swift`
- Modify: `App/Views/Main/DashboardView.swift`

- [ ] **Step 1: Create `CulpritCardView.swift`**

```swift
import SwiftUI

struct CulpritCardView: View {
    let culprit: ProcessCulprit
    let displayMode: CPUDisplayMode
    let remediationEnabled: Bool
    let onQuit: (pid_t, String) -> Void
    let onForceQuit: (pid_t, String) -> Void
    let onThrottle: (pid_t, String) -> Void

    @State private var showForceQuitConfirm = false
    @State private var pendingForceQuit: (pid: pid_t, name: String)?

    var body: some View {
        GroupBox {
            content
                .padding(.vertical, 4)
        }
        .confirmationDialog(
            "Force quit \(pendingForceQuit?.name ?? "process")?",
            isPresented: $showForceQuitConfirm,
            titleVisibility: .visible
        ) {
            Button("Force Quit", role: .destructive) {
                if let p = pendingForceQuit { onForceQuit(p.pid, p.name) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Unsaved work may be lost.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch culprit {
        case .candidate(let pid, let name, let sustainedRawPct):
            candidateView(pid: pid, name: name, rawPct: sustainedRawPct)
        case .macOSCooling:
            informationalView(
                icon: "thermometer.snowflake",
                color: .blue,
                title: "macOS is actively cooling",
                detail: "kernel_task is parking cores to lower the chip temperature. No action needed."
            )
        case .noCPUSource:
            informationalView(
                icon: "exclamationmark.triangle",
                color: .orange,
                title: "Heat source not on CPU",
                detail: "Temperatures are high but no CPU process is sustaining heavy load — likely GPU or I/O."
            )
        case .degraded(let reason):
            informationalView(
                icon: "questionmark.circle",
                color: .secondary,
                title: "Process monitoring unavailable",
                detail: "macOS thermal management is in control. (\(reason))"
            )
        }
    }

    private func candidateView(pid: pid_t, name: String, rawPct: Double) -> some View {
        let displayValue = displayMode == .raw1600
            ? rawPct
            : rawPct / Double(ProcessSampler.logicalCoreCount)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "flame.fill")
                .foregroundStyle(.red)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(name) is sustaining \(String(format: "%.0f", displayValue))% CPU")
                    .font(.body.bold())
                Text("Likely heat source. PID \(pid).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if remediationEnabled {
                    HStack(spacing: 8) {
                        Button("Quit") { onQuit(pid, name) }
                            .buttonStyle(.bordered)
                        Button("Force Quit") {
                            pendingForceQuit = (pid, name)
                            showForceQuitConfirm = true
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        Button("Throttle 10s") { onThrottle(pid, name) }
                            .buttonStyle(.bordered)
                    }
                    .padding(.top, 4)
                } else {
                    Text("Enable remediation in Settings to act on this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            Spacer()
        }
    }

    private func informationalView(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
```

- [ ] **Step 2: Render it in `DashboardView`**

In `DashboardView.swift`, inside `mainPanel`'s `LazyVStack`, **above** the `ProcessListView` call but inside the `if settings.processMonitoringEnabled` block, add:

```swift
if settings.processMonitoringEnabled {
    if let culprit = processMonitor.culprit {
        CulpritCardView(
            culprit: culprit,
            displayMode: settings.cpuDisplayMode,
            remediationEnabled: settings.remediationEnabled,
            onQuit: { pid, name in remediation.terminate(pid: pid, name: name) },
            onForceQuit: { pid, name in remediation.forceQuit(pid: pid, name: name) },
            onThrottle: { pid, name in
                let temps = Dictionary(uniqueKeysWithValues: monitor.temperatures.map { ($0.key, $0.value) })
                remediation.throttle(pid: pid, name: name, currentTemps: temps)
            }
        )
    }

    ProcessListView(
        samples: processMonitor.samples,
        hostCPUPercent: processMonitor.hostCPUPercent,
        displayMode: Binding(
            get: { settings.cpuDisplayMode },
            set: { settings.cpuDisplayMode = $0 }
        )
    )
}
```

(Replace the existing `if settings.processMonitoringEnabled { ProcessListView(...) }` block with the above — the `ProcessListView` is now nested inside the same block.)

- [ ] **Step 3: End-to-end UI test**

Build and launch. The culprit card should be hidden in calm conditions. Now generate sustained load:

```bash
swift -e 'DispatchQueue.concurrentPerform(iterations: 12) { _ in while true {} }' &
```

Wait ~5 seconds. Expected: a red "flame" culprit card appears with the message "swift is sustaining ~75% CPU" (or similar), but the action buttons are hidden because `remediationEnabled` defaults to false. Below the card it says "Enable remediation in Settings to act on this."

Toggle remediation on (you'll add the toggle in Task 16; for now, in the debugger: `e -- settings.remediationEnabled = true` from a breakpoint, or temporarily change the default in `AppSettings.init` to `true`). The three buttons should appear.

- Click **Throttle 10s**. The `swift` process should freeze (Activity Monitor: State = Stopped). It should resume after 10s.
- Click **Quit**. The `swift` process should die within ~3s.
- Restart the load, click **Force Quit**. A confirmation sheet appears. Click "Force Quit" — process dies immediately.

If you bumped `remediationEnabled`'s default to `true` for testing, revert it to `false` before continuing.

```bash
killall swift
```

- [ ] **Step 4: Commit**

```bash
git add App/Views/Components/CulpritCardView.swift App/Views/Main/DashboardView.swift
git commit -m "Add CulpritCardView with action buttons and confirm sheet"
```

---

## Task 15: Background notification on culprit and degraded entry

**Files:**
- Modify: `App/Services/NotificationService.swift`
- Modify: `App/TomsFansApp.swift`

- [ ] **Step 1: Add `notifyCulprit` and `notifyDegraded` to `NotificationService`**

In `App/Services/NotificationService.swift`, add to the class body:

```swift
private var lastCulpritAlertAt: Date?
private let culpritCooldown: TimeInterval = 120   // at most once every 2 minutes
private var degradedNotifiedThisSession = false

func notifyCulprit(name: String, pid: pid_t, rawPct: Double) {
    if let last = lastCulpritAlertAt, Date().timeIntervalSince(last) < culpritCooldown {
        return
    }
    let content = UNMutableNotificationContent()
    content.title = "Heat source detected"
    content.body = "\(name) is sustaining \(Int(rawPct))% CPU. Open Tom's Fans to act."
    content.sound = .default
    let request = UNNotificationRequest(
        identifier: "culprit-\(pid)-\(Int(Date().timeIntervalSince1970))",
        content: content, trigger: nil
    )
    UNUserNotificationCenter.current().add(request)
    lastCulpritAlertAt = Date()
}

func notifyDegraded(reason: String) {
    if degradedNotifiedThisSession { return }
    degradedNotifiedThisSession = true
    let content = UNMutableNotificationContent()
    content.title = "Process monitoring unavailable"
    content.body = "macOS thermal management is in control. (\(reason))"
    content.sound = .default
    let request = UNNotificationRequest(
        identifier: "degraded-\(Int(Date().timeIntervalSince1970))",
        content: content, trigger: nil
    )
    UNUserNotificationCenter.current().add(request)
}
```

- [ ] **Step 2: Subscribe to culprit changes from `TomsFansApp`**

In `App/TomsFansApp.swift`, add a new method:

```swift
private func observeCulpritChanges() {
    processMonitor.$culprit
        .compactMap { $0 }
        .removeDuplicates()
        .sink { [weak notifications] culprit in
            switch culprit {
            case .candidate(let pid, let name, let raw):
                notifications?.notifyCulprit(name: name, pid: pid, rawPct: raw)
            case .degraded(let reason):
                notifications?.notifyDegraded(reason: reason)
            case .macOSCooling, .noCPUSource:
                break    // informational only, no notification
            }
        }
        .store(in: &Self.cancellables)
}
```

In `bootstrapIfNeeded()`, after `observeSleepWake()`, add:

```swift
observeCulpritChanges()
```

- [ ] **Step 3: Build, test background notification**

Build and launch. Close the dashboard window (so it's just menu bar). Run heavy load:

```bash
swift -e 'DispatchQueue.concurrentPerform(iterations: 12) { _ in while true {} }' &
```

Wait ~5s. Expected: a macOS notification appears with "Heat source detected — swift is sustaining ~75% CPU".

Kill the load:
```bash
killall swift
```

- [ ] **Step 4: Commit**

```bash
git add App/Services/NotificationService.swift App/TomsFansApp.swift
git commit -m "Add background notifications for culprit detection and degraded mode"
```

---

## Task 16: Settings toggles + README crash-gap note

**Files:**
- Modify: `App/Views/Main/SettingsView.swift`
- Modify: `README.md`

- [ ] **Step 1: Add the two toggles to `SettingsView`**

Read `App/Views/Main/SettingsView.swift` first to find the existing settings structure. Add a new section (typically a `Form` `Section { ... } header: { Text("...") }`) for task-manager toggles:

```swift
Section {
    Toggle("Monitor processes", isOn: $settings.processMonitoringEnabled)
    Toggle("Allow remediation (Quit / Force Quit / Throttle)", isOn: $settings.remediationEnabled)
        .disabled(!settings.processMonitoringEnabled)
} header: {
    Text("Task Manager")
} footer: {
    Text("Process monitoring identifies likely heat sources. Remediation lets you act on them with one click. Throttled processes are released within 10 seconds or sooner if temperatures drop.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

(If the existing settings file uses a different style — e.g. plain VStack rather than Form — match that style instead.)

- [ ] **Step 2: Update the README**

In `README.md`, append a new section near the end (above any "License" section):

```markdown
## Task Manager (experimental)

Tom's Fans can identify processes that are sustaining heavy CPU load and likely causing heat. When detected, a banner appears with one-click actions to Quit, Force Quit, or temporarily Throttle the process.

**Enable in Settings → Task Manager.** Process monitoring is on by default; remediation actions are opt-in.

**Safety note:** when you Throttle a process, Tom's Fans suspends it (SIGSTOP) for up to 10 seconds, then automatically resumes it (SIGCONT). The app guarantees this auto-resume runs on every normal exit path — including sleep, helper disconnect, and quit.

**Known limitation:** if Tom's Fans itself crashes (not a clean quit) while a process is throttled, that process will remain suspended. To unstick it manually: `kill -CONT <pid>`.
```

- [ ] **Step 3: Build, launch, verify settings toggles work**

```bash
xcodegen generate && xcodebuild -project "Tom's Fans.xcodeproj" -scheme "Tom's Fans" -configuration Debug build
```

Launch. Open Settings (⌘,). Expected: a "Task Manager" section with two toggles. Toggle "Monitor processes" off — the dashboard's process list and culprit card should disappear within one tick. Toggle it back on. Toggle "Allow remediation" off — the culprit card's action buttons should be hidden, but the card itself still appears under load.

- [ ] **Step 4: Final commit**

```bash
git add App/Views/Main/SettingsView.swift README.md
git commit -m "Add Task Manager settings toggles and README documentation"
```

---

## Self-Review Notes

Coverage check vs. spec:

- §1 Goal — covered by Tasks 4, 7, 10, 11, 14 (sampling → correlation → remediation → UI).
- §2 Existing architecture — preserved via Task 1 (`onPollAlways` added as peer, not replacement) and Task 12 (restore closure extended, not replaced).
- §3 Decisions — Tasks 2 (settings), 4 (cadence/scope), 5 (foreground/background), 11 (throttle bounds), 14 (Force Quit confirm), all explicit.
- §4 Components & data flow — Tasks 3–8 build the components; Task 12 wires the data flow.
- §5 XPC + safety invariant — Tasks 9 (protocol), 11 (suspension struct + three resume triggers), 12 (teardown wiring), 13 (manual verification).
- §6 Degraded modes — Task 8 (detection), Task 14 (UI variant), Task 15 (notification).
- §7 Build order — followed by the task numbering, with one exception: §7 step 5 (degraded mode) was placed before XPC extension, which is correct since degraded detection only needs sampling.
- §8.1 Manual safety checklist — Task 13 explicit.
- §8.3 Activity Monitor cross-check — Task 6 step 3.
- §8.4 UI smoke check — Task 14 step 3.
- §9 Known limits — README note in Task 16; documented inline in code where relevant.

Placeholders/ambiguity: none remain. All types and methods referenced in later tasks are defined in earlier tasks (`ThermalCorrelator.neverRankNames`, `ProcessSampler.logicalCoreCount`, `ProcessCulprit` cases, `ProcessRemediationService.terminate/forceQuit/throttle/onTempUpdate/resumeAllSuspended`).

Type consistency: signatures match across tasks. `sendSignal` uses `withReply reply:` matching existing helper convention. `cpuRawPct` / `cpuNormalizedPct` named consistently in model, helper, view.
