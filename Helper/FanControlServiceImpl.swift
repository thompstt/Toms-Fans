import Foundation
import IOKit
import Darwin

/// Implementation of the FanControlProtocol that performs privileged SMC writes.
/// Runs inside the helper tool under root.
///
/// A single instance is shared across all XPC connections (see FanControlDelegate),
/// so it can own a consistent view of which fans we've forced and, in a later step,
/// the unified safety loop (heartbeat, thermal ceiling, duty-cycle throttle).
///
/// All SMC access is serialized on `smcQueue` — the SMC connection is not reentrant.
final class FanControlServiceImpl: NSObject, FanControlProtocol {
    private let connection = SMCConnection()
    private let smcQueue = DispatchQueue(label: "com.tomsfans.helper.smc")
    private lazy var reader = SMCReader(connection: connection)

    /// Fans currently held under forced control. The source of truth for whether
    /// an emergency restore needs to do anything. Touched only on `smcQueue`.
    private var forcedFans: Set<Int> = []

    /// Thermal failsafe state (touched only on `smcQueue`).
    private var guardSensor: FourCharCode?
    private var ceilingC: Double = 0
    /// When tripped, forced writes are rejected until the sensor drops below the
    /// hysteresis band. Prevents the app from immediately re-forcing fans low.
    /// Pure state machine — see Shared/Safety/ThermalLockoutState.swift.
    private var lockout = ThermalLockoutState()
    private var safetyTimer: DispatchSourceTimer?

    /// When live fan enumeration fails (the exact case during an SMC fault), restore
    /// blasts this fixed range instead of trusting a read that may be broken.
    private static let fallbackFanRange = 0..<8
    private static let maxPlausibleRPM: Double = 10_000
    private static let ceilingHysteresisC: Double = 5
    private static let safetyTickInterval: TimeInterval = 1.0

    // MARK: Duty-cycle throttle state (touched only on `throttleQueue`)

    private final class ThrottleEntry {
        let pid: pid_t
        let startTime: UInt64   // proc start time — identity check against PID reuse
        var stopMillis: Int
        var runMillis: Int
        var isStopped = false
        var remainingMs: Int
        init(pid: pid_t, startTime: UInt64, stopMillis: Int, runMillis: Int) {
            self.pid = pid
            self.startTime = startTime
            self.stopMillis = stopMillis
            self.runMillis = runMillis
            self.remainingMs = runMillis   // start in the running phase
        }
    }

    private let throttleQueue = DispatchQueue(label: "com.tomsfans.helper.throttle")
    private var throttles: [pid_t: ThrottleEntry] = [:]
    private var throttleTimer: DispatchSourceTimer?
    private static let throttleTickMs = 50
    private static let throttlePeriodMs = 200
    private static let throttleMinRunMs = 100

    private static let neverSignalNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow",
        "logd", "mds", "mds_stores", "com.tomsfans.helper", "Tom's Fans"
    ]
    private static let allowedSignals: Set<Int32> = [SIGTERM, SIGKILL, SIGSTOP, SIGCONT]

    override init() {
        super.init()
        smcQueue.sync {
            do {
                try connection.open()
            } catch {
                NSLog("FanControlServiceImpl: Failed to open SMC: \(error)")
            }
        }
        startSafetyLoop()
    }

    // MARK: - FanControlProtocol

    func setFanMinSpeed(fanIndex: Int, rpm: Int,
                        withReply reply: @escaping (Bool, String?) -> Void) {
        smcQueue.async {
            guard !self.lockout.lockedOut else {
                reply(false, "thermal protection active — forced control disabled until temperature drops")
                return
            }
            let requested = Double(rpm)
            guard requested.isFinite, requested > 0 else {
                reply(false, "invalid rpm \(rpm)")
                return
            }
            do {
                // Clamp to the fan's live hardware bounds — the trust boundary.
                // If the bounds read back implausible (e.g. a bad SMC decode), refuse
                // the write and hand this fan back to firmware rather than guess.
                let lo = try self.reader.fanMinSpeed(fanIndex: fanIndex)
                let hi = try self.reader.fanMaxSpeed(fanIndex: fanIndex)
                guard lo >= 0, hi > lo, hi < Self.maxPlausibleRPM else {
                    try? self.writeUInt8(key: SMCKey.fanMode(fanIndex), value: 0)
                    self.forcedFans.remove(fanIndex)
                    reply(false, "implausible fan \(fanIndex) bounds (min \(lo), max \(hi)) — reverted to auto")
                    return
                }
                let clamped = min(max(requested, lo), hi)
                // Write to F*Tg (target), not F*Mn (min) — F*Mn is read-only on MacBook Pro 16,1
                try self.writeFanFloat(key: SMCKey.fanTarget(fanIndex), value: Float(clamped))
                reply(true, nil)
            } catch {
                reply(false, error.localizedDescription)
            }
        }
    }

    func setFanMode(fanIndex: Int, mode: UInt8,
                    withReply reply: @escaping (Bool, String?) -> Void) {
        smcQueue.async {
            // Forcing is blocked during thermal lockout; reverting to auto is always allowed.
            if mode != 0, self.lockout.lockedOut {
                reply(false, "thermal protection active — forced control disabled until temperature drops")
                return
            }
            do {
                try self.writeUInt8(key: SMCKey.fanMode(fanIndex), value: mode)
                if mode == 0 {
                    self.forcedFans.remove(fanIndex)
                } else {
                    self.forcedFans.insert(fanIndex)
                }
                reply(true, nil)
            } catch {
                reply(false, error.localizedDescription)
            }
        }
    }

    func setThermalGuard(sensorKey: String, ceilingC: Double,
                         withReply reply: @escaping (Bool, String?) -> Void) {
        smcQueue.async {
            if sensorKey.utf8.count == 4, ceilingC > 0 {
                self.guardSensor = FourCharCode(sensorKey)
                // Never arm above Tjmax — a higher "ceiling" would be worse than Off.
                self.ceilingC = min(ceilingC, ThermalCeiling.maxC)
            } else {
                // Disable the guard and clear any standing lockout.
                self.guardSensor = nil
                self.ceilingC = 0
                self.lockout.disable()
            }
            reply(true, nil)
        }
    }

    func restoreAutomaticControl(withReply reply: @escaping (Bool, String?) -> Void) {
        smcQueue.async {
            let (ok, err) = self.performRestore(panic: false)
            reply(ok, err)
        }
    }

    func getHelperVersion(withReply reply: @escaping (String) -> Void) {
        reply(XPCConstants.helperVersion)
    }

    func sendSignal(_ signal: Int32, toPID pid: pid_t,
                    withReply reply: @escaping (Bool, String?) -> Void) {
        guard Self.allowedSignals.contains(signal) else {
            reply(false, "signal \(signal) not allowed")
            return
        }
        guard pid > 1 else {
            reply(false, "PID \(pid) is protected (kernel/launchd)")
            return
        }
        if pid == getpid() {
            reply(false, "refused to signal helper itself")
            return
        }
        var nameBuf = [CChar](repeating: 0, count: 1024)
        let written = proc_name(pid, &nameBuf, UInt32(nameBuf.count))
        if written > 0 {
            let name = String(cString: nameBuf)
            if Self.neverSignalNames.contains(name) {
                reply(false, "process \(name) is on the never-signal list")
                return
            }
        }
        let result = kill(pid, signal)
        if result == 0 {
            reply(true, nil)
        } else {
            reply(false, "kill(\(pid), \(signal)) failed: errno=\(errno)")
        }
    }

    func startThrottle(pid: pid_t, level: Double,
                       withReply reply: @escaping (Bool, String?) -> Void) {
        guard pid > 1 else { reply(false, "PID \(pid) is protected"); return }
        if pid == getpid() { reply(false, "refused to throttle helper itself"); return }
        if let name = Self.processName(pid), Self.neverSignalNames.contains(name) {
            reply(false, "process \(name) is on the never-signal list")
            return
        }
        guard let startTime = Self.procStartTime(pid) else {
            reply(false, "process \(pid) not found")
            return
        }

        // Translate level (fraction suspended) into a run/stop split, enforcing a
        // minimum run slice so a high level can never fully starve the process.
        let clamped = min(max(level, 0.0), 0.95)
        var runMs = Int(Double(Self.throttlePeriodMs) * (1.0 - clamped))
        if runMs < Self.throttleMinRunMs { runMs = Self.throttleMinRunMs }
        let stopMs = max(0, Self.throttlePeriodMs - runMs)

        throttleQueue.async {
            self.throttles[pid] = ThrottleEntry(pid: pid, startTime: startTime,
                                                stopMillis: stopMs, runMillis: runMs)
            self.ensureThrottleTimer()
            reply(true, nil)
        }
    }

    func stopThrottle(pid: pid_t, withReply reply: @escaping (Bool, String?) -> Void) {
        throttleQueue.async {
            self.removeThrottle(pid)
            reply(true, nil)
        }
    }

    // MARK: - Emergency restore (internal)

    /// Called by the dead-man's switch and the XPC invalidation handler when the
    /// app may have died. No-op if we aren't holding any fan forced — so a clean
    /// quit (app already restored Auto) doesn't blip the fans.
    func emergencyRestore() {
        smcQueue.async {
            guard !self.forcedFans.isEmpty else { return }
            NSLog("FanControlServiceImpl: emergency restore — %d fan(s) were forced", self.forcedFans.count)
            _ = self.performRestore(panic: true)
        }
    }

    /// Resume and forget every throttled process. Called when the app disconnects so a
    /// throttle never outlives the controller — the process is left running, never stopped.
    func emergencyResumeThrottles() {
        throttleQueue.async {
            guard !self.throttles.isEmpty else { return }
            NSLog("FanControlServiceImpl: app gone — resuming %d throttled process(es)", self.throttles.count)
            for (pid, entry) in self.throttles where Self.procStartTime(pid) == entry.startTime {
                _ = kill(pid, SIGCONT)
            }
            self.throttles.removeAll()
            self.stopThrottleTimer()
        }
    }

    // MARK: - Safety loop

    /// The single root-side loop. Runs for the helper's lifetime; only acts while
    /// fans are forced. Currently enforces the thermal ceiling; the heartbeat /
    /// dead-man and duty-cycle throttle will hang off the same tick.
    private func startSafetyLoop() {
        let timer = DispatchSource.makeTimerSource(queue: smcQueue)
        timer.schedule(deadline: .now() + Self.safetyTickInterval,
                       repeating: Self.safetyTickInterval)
        timer.setEventHandler { [weak self] in self?.safetyTick() }
        timer.resume()
        safetyTimer = timer
    }

    private func safetyTick() {
        dispatchPrecondition(condition: .onQueue(smcQueue))
        guard let sensor = guardSensor, ceilingC > 0 else { return }
        // Keep ticking while locked out even though the trip un-forced every fan —
        // otherwise the clear path is unreachable and the lockout latches forever.
        guard lockout.lockedOut || !forcedFans.isEmpty else { return }
        guard let temp = try? reader.readTemperature(key: sensor) else { return }

        switch lockout.evaluate(fansForced: !forcedFans.isEmpty, temp: temp,
                                ceilingC: ceilingC, hysteresisC: Self.ceilingHysteresisC) {
        case .trip:
            NSLog("FanControlServiceImpl: thermal ceiling %.0fC reached (%.1fC) — reverting fans to auto",
                  ceilingC, temp)
            _ = performRestore(panic: true)
        case .clear:
            NSLog("FanControlServiceImpl: thermal lockout cleared (%.1fC)", temp)
        case .none:
            break
        }
    }

    // MARK: - Throttle engine

    private func ensureThrottleTimer() {
        dispatchPrecondition(condition: .onQueue(throttleQueue))
        guard throttleTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: throttleQueue)
        let interval = DispatchTimeInterval.milliseconds(Self.throttleTickMs)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.throttleTick() }
        timer.resume()
        throttleTimer = timer
    }

    private func stopThrottleTimer() {
        throttleTimer?.cancel()
        throttleTimer = nil
    }

    /// Stop tracking a PID and guarantee it is left running.
    private func removeThrottle(_ pid: pid_t) {
        dispatchPrecondition(condition: .onQueue(throttleQueue))
        guard let entry = throttles.removeValue(forKey: pid) else { return }
        if Self.procStartTime(pid) == entry.startTime {
            _ = kill(pid, SIGCONT)   // idempotent; safe even if already running
        }
        if throttles.isEmpty { stopThrottleTimer() }
    }

    private func throttleTick() {
        dispatchPrecondition(condition: .onQueue(throttleQueue))
        for (pid, entry) in throttles {
            // Identity guard: if the process is gone or the PID was reused, drop it
            // WITHOUT signaling — never SIGSTOP/SIGCONT a stranger.
            guard Self.procStartTime(pid) == entry.startTime else {
                throttles.removeValue(forKey: pid)
                continue
            }
            entry.remainingMs -= Self.throttleTickMs
            if entry.remainingMs > 0 { continue }
            if entry.isStopped {
                _ = kill(pid, SIGCONT)
                entry.isStopped = false
                entry.remainingMs = entry.runMillis
            } else if entry.stopMillis > 0 {
                _ = kill(pid, SIGSTOP)
                entry.isStopped = true
                entry.remainingMs = entry.stopMillis
            } else {
                entry.remainingMs = entry.runMillis   // level too low to suspend
            }
        }
        if throttles.isEmpty { stopThrottleTimer() }
    }

    private static func procStartTime(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard r == size else { return nil }
        return UInt64(info.pbi_start_tvsec)
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 1024)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    // MARK: - Private

    /// Hand every fan back to firmware. Never trusts cached state.
    /// - clean: write mode 0 (auto) per fan. Quiet — used for sleep / user→Auto.
    /// - panic: write mode 0 AND target→max, best-effort, ignoring per-fan errors.
    ///   Used when something is wrong (dead-man, thermal ceiling, SMC fault) and we
    ///   want maximum cooling even if firmware honors a lingering target.
    /// Enumerates the live fan count; if that read fails, falls back to a fixed
    /// range so a broken SMC doesn't turn restore into a silent no-op.
    private func performRestore(panic: Bool) -> (Bool, String?) {
        dispatchPrecondition(condition: .onQueue(smcQueue))

        let indices: Range<Int>
        if let count = try? reader.fanCount(), count > 0 {
            indices = 0..<min(count, Self.fallbackFanRange.upperBound)
        } else {
            indices = Self.fallbackFanRange
        }

        var wrote = 0
        var errors: [String] = []
        for i in indices {
            do {
                try writeUInt8(key: SMCKey.fanMode(i), value: 0)
                wrote += 1
                forcedFans.remove(i)
                if panic, let hi = try? reader.fanMaxSpeed(fanIndex: i),
                   hi > 0, hi < Self.maxPlausibleRPM {
                    try? writeFanFloat(key: SMCKey.fanTarget(i), value: Float(hi))
                }
            } catch {
                errors.append("fan \(i): \(error.localizedDescription)")
            }
        }

        // In panic/fallback we expect writes to phantom indices to fail — success
        // means at least one real fan was handed back. In clean mode every write
        // should succeed.
        if panic {
            return (wrote > 0, wrote > 0 ? nil : "restore wrote nothing")
        }
        return (errors.isEmpty, errors.isEmpty ? nil : errors.joined(separator: "; "))
    }

    private func writeFanFloat(key: FourCharCode, value: Float) throws {
        // Get key info first — SMC validates both dataType AND dataSize on writes
        let info = try reader.getKeyInfo(key)

        var input = SMCParamStruct()
        input.key = key
        input.data8 = SMCSelector.kSMCWriteKey.rawValue
        input.keyInfo.dataSize = info.dataSize
        input.keyInfo.dataType = info.dataType

        // Write float in little-endian (native on Intel)
        withUnsafeBytes(of: value) { srcBytes in
            withUnsafeMutableBytes(of: &input.bytes) { destBytes in
                for i in 0..<4 {
                    destBytes[i] = srcBytes[i]
                }
            }
        }

        _ = try connection.callDriver(input: &input)
    }

    private func writeUInt8(key: FourCharCode, value: UInt8) throws {
        let info = try reader.getKeyInfo(key)

        var input = SMCParamStruct()
        input.key = key
        input.data8 = SMCSelector.kSMCWriteKey.rawValue
        input.keyInfo.dataSize = info.dataSize
        input.keyInfo.dataType = info.dataType

        withUnsafeMutableBytes(of: &input.bytes) { bytes in
            bytes[0] = value
        }

        _ = try connection.callDriver(input: &input)
    }
}
