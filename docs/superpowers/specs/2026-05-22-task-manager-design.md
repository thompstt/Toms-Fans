# Task Manager Feature — Design

**Date:** 2026-05-22
**Status:** Approved, ready for implementation planning
**Target machine:** Intel MacBook Pro, 8-core i9 (16 logical cores → CPU ceiling 1600%)

## 1. Goal

Add a thermal-aware task manager that:

1. Samples per-process resource usage on the existing poll loop.
2. Correlates resource spikes with thermal events to identify likely heat culprits.
3. Alerts the user and offers **one-click manual remediation** (terminate or throttle the offending process).

**Tier 3 / manual scope:** every remediation action is initiated by a user click. No automatic killing/throttling. Auto-remediation is explicitly deferred.

The strategic payoff is that process load is a *leading* indicator of heat, where temperature is a *lagging* one. This phase builds the foundation (monitoring + correlation + manual action) for future predictive fan-curve work.

## 2. Existing architecture to preserve

All wiring lives in `App/TomsFansApp.swift`. The new feature must not break these contracts:

| Object | Role | Key symbols |
|---|---|---|
| `SMCMonitorService` (`monitor`) | Thermal poll loop, history | `onPoll`, `onSafetyRestore`, `updatePollInterval`, `pausePolling`/`resumePolling`, `isCollectingHistory`, `clearHistory`, `fans`, `menuBarLabel` |
| `XPCFanControlService` (`fanControl`) | Privileged helper bridge | `onDisconnect`, `restoreAutomatic`, `errorLog` |
| `HelperInstallService` | Helper installer (SMAppService) | Reused for any new helper entitlements |
| `FanCurveEngine` (`curveEngine`) | Curve evaluation | `onSafetyRestore`, `reset` |
| `AppSettings` (`settings`) | Persisted config | `pollInterval`, `controlMode`, `alertThresholds` |
| `NotificationService` (`notifications`) | User notifications | `checkThresholds`, `setup` |
| `ErrorLog` (`errorLog`) | Shared error logging | Injected into all services |

**Patterns to mirror:**

- **Single poll heartbeat.** `monitor.onPoll` fires every tick with `temps`; curve eval + notifications hang off it. Process sampling becomes a peer — no second timer.
- **Safety-restore fan-out.** `setupSafetyCallbacks()` wires one `restore` closure into `monitor.onSafetyRestore`, `curveEngine.onSafetyRestore`, and `fanControl.onDisconnect`. Remediation hooks the same path.
- **Sleep/wake handling.** `observeSleepWake()` pauses polling + restores automatic on sleep, resumes on wake.
- **Lifecycle.** `AppDelegate.isTerminating`, `applicationWillTerminate`. App keeps running in menu bar after window close.

## 3. Decisions

| Area | Decision |
|---|---|
| Scope | Process monitoring on by default. Background (window closed): lightweight — top 15 PIDs by current CPU, no per-PID ring buffer. Foreground (window open): full per-PID sampling + 60 s ring buffer. |
| Cadence | Single heartbeat — process sampling runs inside `monitor.onPoll`, no second timer. |
| Settings | Two `AppSettings` flags. `processMonitoringEnabled` defaults true. `remediationEnabled` defaults false; gates the kill/throttle action buttons only. Third flag `cpuDisplayMode` for raw-1600 vs. normalized-100. |
| Throttle bounds | `SIGSTOP` → resume after **10 s max** OR earlier when any monitored temp drops **≥ 5 °C** from the value at suspend time. |
| Confirmation | Quit (SIGTERM) and Throttle are one-click. Force Quit (SIGKILL) shows a "may lose unsaved work" confirm sheet. |
| Heat-share estimate via `powermetrics` | Deferred. |
| Duty-cycle throttling (v2) | Deferred. |

## 4. Components & data flow

### 4.1 New files

```
App/Services/
  ProcessMonitorService.swift     // @StateObject, owns ThermalCorrelator
  ProcessRemediationService.swift // @StateObject, weak ref to XPCFanControlService
  ThermalCorrelator.swift         // plain class, owned by ProcessMonitorService

App/Models/
  ProcessSample.swift             // pid, name, path, cpuRawPct, cpuNormalizedPct, rssBytes
  ProcessCulprit.swift            // .candidate(pid, name, sustainedRawPct, evidenceWindow)
                                  // .macOSCooling   (kernel_task high)
                                  // .noCPUSource    (temps high, no PID exceeds threshold)
                                  // .degraded       (process data untrusted — §7)

Shared/XPCProtocol/
  FanControlProtocol.swift        // extended with sendSignal(...)

Helper/
  FanControlServiceImpl.swift     // extended with server-side validation + kill()
```

### 4.2 Settings additions (`App/Models/AppSettings.swift`)

```swift
@Published var processMonitoringEnabled: Bool   // default true,  UserDefaults
@Published var remediationEnabled: Bool         // default false, UserDefaults
@Published var cpuDisplayMode: CPUDisplayMode   // .raw1600 | .normalized100, default .normalized100
```

Same `didSet`-into-UserDefaults pattern as existing `pollInterval`.

### 4.3 `ProcessMonitorService`

**Sampling:**

- Enumerate PIDs via `proc_listpids`.
- Per-PID CPU time via `proc_pid_rusage` (`RUSAGE_INFO_V*` — `ri_user_time` + `ri_system_time`; capture energy fields where available on Intel).
- Memory via `task_info` / rusage resident size.
- Process name/path via `proc_pidpath` / `proc_name`.

**Rate computation:**

- Track previous tick's cumulative CPU time per PID.
- `rawPct = (Δcpu_time / Δwall_time) × 100` — native 0–1600 range (1 saturated core = 100%).
- `normalizedPct = rawPct / 16` (0–100, Windows-familiar). Both exposed; UI toggles which to show.

**Foreground/background modes:**

- `setForegroundMode(true)` (called from window `onAppear`): full enumeration, fill 60 s per-PID ring buffer.
- `setForegroundMode(false)` (called from window `onDisappear`): drop ring buffer; sample only top 15 PIDs by current rate, re-ranked each tick. Sufficient for the correlator to still flag a runaway in the background.

**System cross-check:** call `host_processor_info` each tick to get ground-truth total CPU. Used by §7 degraded-mode detection and by `ThermalCorrelator` for the "no CPU culprit found" branch.

### 4.4 `ThermalCorrelator`

Owned by `ProcessMonitorService`. Triggered every tick.

**Trigger conditions** (either fires the correlator):

- `ProcessInfo.thermalState` rises to `.serious` or `.critical` (subscribe to `thermalStateDidChangeNotification`).
- A single PID has sustained `rawPct > 840` (> 70% of total machine CPU) for ≥ 3 consecutive ticks.

**Ranking:** by sustained Δcpu over the preceding window (sustained load over instantaneous blips).

**Special cases:**

- `kernel_task` is excluded from culprit ranking. When `kernel_task` itself is > 100% rawPct, publish `.macOSCooling` informational state.
- If trigger fires but no non-excluded PID exceeds threshold → publish `.noCPUSource` ("likely GPU/IO — no CPU culprit found").

**Never-rank list** (same set used by remediation's never-signal filter): `kernel_task`, `launchd` (PID 0/1), `WindowServer`, `loginwindow`, `logd`, `mds`, `mds_stores`, our app, our helper.

### 4.5 Per-tick data flow

```
monitor.onPoll(temps) ──┬──► [existing] curveEngine.evaluate(...)
                        ├──► [existing] notifications.checkThresholds(temps, ...)
                        ├──► remediation.onTempUpdate(temps)   // checks early-resume condition
                        └──► processMonitor.sample()           // gated by processMonitoringEnabled
                                ├─► enumerate PIDs
                                ├─► per PID: proc_pid_rusage → Δcpu → rawPct, normalizedPct
                                ├─► foreground? push into per-PID ring buffer
                                ├─► degraded-mode check (§7)
                                └─► correlator.evaluate(temps, samples) → @Published culprit
```

### 4.6 UI surface

New section in `DashboardView`:

```
Processes section
 ├── Toggle: raw % (0–1600) ↔ normalized % (0–100)
 ├── Sortable table: name | CPU% | mem | (energy if available)
 └── Culprit card (visible only when culprit != nil)
      ├── .candidate     → "<name> sustaining X% CPU"
      │                    [Quit] [Force Quit*] [Throttle 10s]
      │                    *opens confirm sheet
      │                    Buttons hidden when remediationEnabled = false
      ├── .macOSCooling  → "macOS is cooling via kernel_task — no action needed"
      ├── .noCPUSource   → "Temps high but no CPU culprit — likely GPU/IO"
      └── .degraded      → "Process monitoring unavailable — macOS thermal management is in control"
                           (see §7; no action buttons)
```

`NotificationService.notifyCulprit(_:)` — new method for background alerts when window is closed. Clicking the notification opens the dashboard.

### 4.7 Wire-up in `TomsFansApp`

```swift
@StateObject private var processMonitor = ProcessMonitorService()
@StateObject private var remediation    = ProcessRemediationService()
```

- `bootstrapIfNeeded()`: inject `errorLog`; pass `fanControl` as weak ref into `remediation`.
- `setupPollCallback()`: add `processMonitor?.sample(temps:)` (gated by `settings.processMonitoringEnabled`) and `remediation?.onTempUpdate(temps)`.
- `setupSafetyCallbacks()`: extend the shared `restore` closure to call `remediation?.resumeAllSuspended()` **first**, before fan restore.
- `observeSleepWake()`: `willSleepNotification` calls `remediation?.resumeAllSuspended()`.
- `AppDelegate.applicationWillTerminate`: upgraded to call `remediation?.resumeAllSuspended()` synchronously (with the §5 fallback path).
- Window `onDisappear`: `processMonitor.setForegroundMode(false)` parallel to `monitor.clearHistory()`.

## 5. XPC helper extension & safety invariant

### 5.1 Protocol extension

`Shared/XPCProtocol/FanControlProtocol.swift`:

```swift
@objc protocol FanControlProtocol {
    // ...existing fan methods...

    /// Send a POSIX signal to a PID. Helper validates the PID server-side
    /// against the never-signal list.
    func sendSignal(_ signal: Int32, toPID pid: pid_t,
                    reply: @escaping (Bool, NSError?) -> Void)
}
```

Allowed signals only: `SIGTERM` (15), `SIGKILL` (9), `SIGSTOP` (17), `SIGCONT` (19).

### 5.2 Helper-side validation (defense in depth)

`Helper/FanControlServiceImpl.swift`:

1. Reject any signal not in the allowed set.
2. Reject `pid <= 1`.
3. Reject our own app PID and helper PID.
4. Resolve `proc_name(pid)` and reject the never-signal name list (`kernel_task`, `WindowServer`, `loginwindow`, `launchd`, `logd`, `mds`, `mds_stores`, `com.tomsfans.helper`).
5. Call `kill(pid, sig)`; reply `(result == 0, errno-as-NSError)`.

Client also filters this list; helper is the chokepoint.

### 5.3 `ProcessRemediationService` API

```swift
final class ProcessRemediationService: ObservableObject {
    weak var xpc: XPCFanControlService?
    var errorLog: ErrorLog?

    private struct Suspension {
        let pid: pid_t
        let name: String
        let suspendedAt: Date
        let tempsAtSuspend: [String: Double]    // sensor → °C snapshot
        var resumeWorkItem: DispatchWorkItem?   // 10s hard deadline
    }
    private var suspendedPIDs: [pid_t: Suspension] = [:]
    private let queue = DispatchQueue(label: "remediation", qos: .userInitiated)

    func terminate(pid: pid_t, name: String)                // SIGTERM, SIGKILL after 3s if alive
    func forceQuit(pid: pid_t, name: String)                // SIGKILL immediately
    func throttle(pid: pid_t, name: String,
                  currentTemps: [String: Double])           // SIGSTOP + resume triggers

    func onTempUpdate(_ temps: [String: Double])            // early-resume check
    func resumeAllSuspended()                               // safety net
}
```

### 5.4 The safety invariant

> Every PID placed into `suspendedPIDs` will receive `SIGCONT` before being removed from that map. No path out except via `SIGCONT`.

Three independent resume triggers per suspension:

1. **Hard deadline.** `DispatchWorkItem` posted at suspend time with 10 s delay. Calls `resume(pid:)`.
2. **Temp recovery.** Every tick, `onTempUpdate(temps)` walks `suspendedPIDs`; if any sensor dropped ≥ 5 °C from `tempsAtSuspend`, calls `resume(pid:)` early (cancels the deadline).
3. **Catastrophic resume.** `resumeAllSuspended()` walks the map and `SIGCONT`s everything, cancelling all work items. Wired into:
   - Shared `restore` closure (helper disconnect, monitor safety, curve safety) — called **before** the fan-restore branch.
   - `observeSleepWake()` → `willSleepNotification`.
   - `applicationWillTerminate` (synchronous, with fallback below).
   - `deinit` of the service.

`resume(pid:)` is the single mutation point: removes from `suspendedPIDs`, sends `SIGCONT`, cancels the work item — all three or none.

### 5.5 Termination escalation

`terminate(pid:name:)`:

1. Send `SIGTERM` via XPC.
2. Schedule a 3 s `DispatchWorkItem` that checks `kill(pid, 0) == 0` (alive probe).
3. If alive, send `SIGKILL`.

User clicks "Quit" once; the escalation is automatic.

### 5.6 Force Quit confirmation UX

`.confirmationDialog` attached to the Force Quit button. Text: `"Force quit \(name)? Unsaved work may be lost."` Buttons: `Force Quit` (destructive role) / `Cancel`.

### 5.7 Failure modes

| Failure | Behavior |
|---|---|
| Helper not installed | Action buttons disabled with tooltip "Install helper in Settings" (mirrors fan-control). |
| `kill()` returns ESRCH | PID died between rank and signal — silently succeed. |
| `kill()` returns EPERM | Log to `errorLog`. Likely SIP-protected; should have been filtered upstream. |
| Helper disconnects mid-throttle | `fanControl.onDisconnect` → `restore` → `resumeAllSuspended()` → fallback path. |
| Helper unreachable during `resumeAllSuspended()` | Fallback to direct `kill(pid, SIGCONT)` per tracked PID. Legal for same-user processes; harmless to a running process. |
| App crash while PID is suspended | `applicationWillTerminate` does not fire on crash. **Documented v1 gap** — surfaced in README. Watchdog out of scope. |

## 6. Failure modes specific to monitoring (degraded modes)

The fan-control side has a known bug where SMC RPM reads fail and curves can't evaluate safely. Process monitoring has the same failure shape — missing input → wrong output → user-visible action against bad data — even though the underlying syscalls (`proc_*`) are more uniform across Macs than SMC keys.

**Detection — two signals, either trips degraded mode:**

1. `proc_listpids` returns fewer than 20 PIDs (sanity floor — a fresh macOS has 200+).
2. Sum of visible per-PID `rawPct` is more than 50 points below `host_processor_info`'s reported total CPU.

Either condition for **3 consecutive ticks** → enter degraded mode. One clean tick → exit.

**Behavior when degraded:**

- Stop running correlation. Publish `culprit = .degraded`.
- Hide all action buttons. Culprit card replaced by the banner:
  > "Process monitoring unavailable — macOS thermal management is in control."
- Fire a one-shot user notification via `NotificationService` on first entry per session (coalesced).
- Process list view stays visible with whatever PIDs we did see, with a "Limited data" badge.
- Log the trigger reason (low PID count vs. CPU gap) to `errorLog` once per entry.

**Remediation safety:** if any PID is currently suspended when degraded mode is entered, `resumeAllSuspended()` runs immediately. No suspension survives blindness.

No partial-blindness handling. When uncertain, step back entirely and let macOS manage thermals — same instinct as the fan-control safety restore.

## 7. Build order

1. `ProcessMonitorService` sampling + rate computation (raw + normalized). Acceptance: per-PID CPU% within ~5% of Activity Monitor under a known load (`yes > /dev/null × 4`).
2. Ring buffer + history wiring (mirror `isCollectingHistory`).
3. Process list UI (read-only) with raw/normalized toggle. Gated on `processMonitoringEnabled` (default true).
4. `ThermalCorrelator` + culprit ranking, including `kernel_task` special case and `.noCPUSource` branch.
5. Degraded-mode detection (§6) and UI banner.
6. XPC helper protocol extension for `sendSignal`, with server-side never-signal validation.
7. `ProcessRemediationService` — `terminate` first (TERM → KILL escalation), then `throttle` (bounded SIGSTOP/CONT).
8. Wire `resumeAllSuspended()` into all teardown paths. **Run the manual safety-invariant checklist (§9) before moving on.**
9. Culprit-card UI + one-click buttons + Force Quit confirm sheet. Gated on `remediationEnabled` (default false).
10. Background notification via `NotificationService.notifyCulprit`.

## 8. Testing & verification

No XCTest target exists in the repo today; deferring scaffolding one until a second feature needs it. For v1:

### 8.1 Manual safety-invariant checklist (must pass before merge)

Each test starts with a known-suspended PID (`yes > /dev/null &` → throttle from dashboard), triggers a teardown path, then verifies the PID is `Running` (not `Stopped`) in Activity Monitor.

| Scenario | Trigger | Expected |
|---|---|---|
| Hard deadline | Throttle, wait 10 s | PID resumed at ~10 s |
| Early resume | Throttle, then cool CPU manually | PID resumed when any sensor drops ≥ 5 °C |
| Sleep mid-throttle | Throttle, then `pmset sleepnow` | PID resumed at sleep |
| Helper disconnect | Throttle, then `launchctl kill SIGTERM` on helper | PID resumed via fallback `kill()` |
| App quit | Throttle, then ⌘Q | PID resumed before exit |
| Safety restore (curve) | Throttle while curve running, trip safety | PID resumed |
| App crash | Throttle, then `kill -9` the app | **Documented gap**: PID stays Stopped. README warns. |

### 8.2 Pure-logic functions to keep testable

Lift to free functions / static methods so they're verifiable ad-hoc:

- Rate computation: `(prevCPU, currCPU, prevWall, currWall) → (rawPct, normalizedPct)`. Edge cases: PID disappeared, wall delta = 0, counter wraparound.
- Correlator ranking: given a ring buffer of fixture samples, assert the right PID ranks top; `kernel_task` is filtered; `.noCPUSource` fires when no PID exceeds threshold.
- Never-signal filter: given `(pid, name)` pairs, assert the blocked set is rejected.

### 8.3 Activity Monitor cross-check (build step 1 gate)

Side-by-side under `yes > /dev/null × 4`. Per-PID CPU% within ~5% of Activity Monitor. Raw mode (0–1600) matches their per-CPU view.

### 8.4 UI smoke check

Launch from Xcode, exercise each button against a real `yes` process, watch the culprit card appear/disappear naturally as load comes and goes.

## 9. Known limits & gotchas

- Per-process sums exceed 100%; compare against 1600, cross-check with `host_processor_info`.
- `ProcessInfo.thermalState` is coarse and lagging — own CPU thresholds drive early detection.
- GPU-per-process attribution is not cleanly available — flag via `.noCPUSource`, never fabricate.
- SIP-protected processes can be observed but not signaled — excluded by the never-signal list.
- `kernel_task` at high % is macOS cooling the i9, never a culprit, never a kill target.
- App crash with a process suspended → orphaned `SIGSTOP`. Documented gap; watchdog deferred.
