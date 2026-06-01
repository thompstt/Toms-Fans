import Foundation
import IOKit

struct TemperatureReading: Identifiable, Equatable {
    let id: Int  // Sequential counter, not UUID (avoids allocation)
    let date: Date
    let value: Double
}

/// Polls SMC sensors on a timer, publishes state for the UI.
/// Optimized to only trigger @Published when values meaningfully change.
///
/// Threading model:
/// - `smcQueue` (serial) owns ALL SMC I/O — the connection, the reader, the poll
///   timer, the working-set arrays, and the poll counters. SMC operations therefore
///   never run concurrently (the connection/reader are not reentrant) and never race.
/// - The main thread is the ONLY writer of the @Published properties. The poll work
///   builds a snapshot on `smcQueue` and hands it to main; the serial queue never
///   reads the @Published arrays.
final class SMCMonitorService: ObservableObject {
    @Published var temperatures: [TemperatureSensor] = []
    @Published var fans: [Fan] = []
    @Published var chartHistory: [String: [TemperatureReading]] = [:]
    private var _fullHistory: [String: [TemperatureReading]] = [:]
    @Published var menuBarLabel: String = "--°C"
    @Published var isConnected = false
    private(set) var sensorNames: [String: String] = [:]

    // MARK: - smcQueue-owned state (touched ONLY on smcQueue)

    private let smcQueue = DispatchQueue(label: "com.tomsfans.smc", qos: .userInitiated)
    private var reader: SMCReader?
    private let connection = SMCConnection()
    private var pollTimer: DispatchSourceTimer?
    /// The authoritative working copy of the models, mutated in place each poll.
    private var workingTemps: [TemperatureSensor] = []
    private var workingFans: [Fan] = []
    /// What the UI currently shows — used to compute publish deltas without ever
    /// reading the @Published arrays off the main thread.
    private var publishedTemps: [TemperatureSensor] = []
    private var publishedFans: [Fan] = []
    private var pollInterval: TimeInterval = 1.0
    private var currentInterval: TimeInterval = 1.0
    private var pollCount = 0
    private var consecutiveReadFailures = 0
    /// True while a wake-reconnect retry chain is in flight — prevents overlapping
    /// wakes from spawning duplicate chains.
    private var isReconnecting = false

    private let idlePollInterval: TimeInterval = 5.0
    private let maxHistoryDuration = TemperatureHistoryRange.maximumDuration

    // MARK: - Main-owned state

    private var readingCounter = 0

    var errorLog: ErrorLog?
    var onSafetyRestore: (() -> Void)?
    var isCollectingHistory = true

    func clearHistory() {
        _fullHistory.removeAll()
        chartHistory.removeAll()
    }

    var onPoll: (([TemperatureSensor]) -> Void)?
    /// Fires on every poll tick, regardless of temperature delta.
    /// Use for samplers that need a heartbeat independent of temperature changes
    /// (e.g. process sampling, where load is a leading indicator of heat).
    var onPollAlways: (() -> Void)?

    // MARK: - Cached Summary Temps (main-owned; updated on the publish hop)

    private(set) var cpuPackageTemp: Double = 0
    private(set) var gpuTemp: Double = 0

    private func updateSummaryTemps(_ sensors: [TemperatureSensor]) {
        cpuPackageTemp = sensors.first(where: { $0.key == "TCXC" })?.value
            ?? sensors.filter({ $0.key.hasPrefix("TC") }).map(\.value).max()
            ?? 0
        gpuTemp = sensors.first(where: { $0.key == "TG0P" })?.value ?? 0
    }

    init() {
        smcQueue.sync {
            do {
                try connection.open()
                reader = SMCReader(connection: connection)
            } catch {
                reader = nil
            }
        }
        isConnected = (reader != nil)
        if reader != nil {
            discoverSensors()
        }
    }

    deinit {
        pollTimer?.cancel()
        connection.close()
    }

    // MARK: - Polling control (all timer state lives on smcQueue)

    func updatePollInterval(_ interval: TimeInterval) {
        smcQueue.async { [weak self] in
            guard let self, interval > 0, interval != self.pollInterval else { return }
            self.pollInterval = interval
            // Only restart if we're using the active rate (not idle).
            if self.currentInterval != self.idlePollInterval {
                self.currentInterval = interval
                self.schedulePollTimer()
            }
        }
    }

    func pausePolling() {
        smcQueue.async { [weak self] in
            self?.pollTimer?.cancel()
            self?.pollTimer = nil
        }
    }

    func resumePolling() {
        smcQueue.async { [weak self] in
            guard let self, self.pollTimer == nil, !self.isReconnecting else { return }
            self.isReconnecting = true
            self.reconnectAfterWake()
        }
    }

    func setIdleMode(_ idle: Bool) {
        smcQueue.async { [weak self] in
            guard let self else { return }
            let target = idle ? self.idlePollInterval : self.pollInterval
            guard target != self.currentInterval else { return }
            self.currentInterval = target
            self.schedulePollTimer()
        }
    }

    // MARK: - Private (smcQueue)

    /// Reconnect the SMC after wake and resume polling. Backs off but NEVER gives up:
    /// a hardware/SMC that's slow to wake must not leave monitoring (and the failsafe
    /// that depends on it) permanently dead. Delays: 1s, 2s, 5s, then capped at 10s.
    private func reconnectAfterWake(attempt: Int = 0) {
        let delay: TimeInterval
        switch attempt {
        case 0: delay = 1.0
        case 1: delay = 2.0
        case 2: delay = 5.0
        default: delay = 10.0
        }
        smcQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard let reader = self.reader else { self.isReconnecting = false; return }

            // Reconnect — IOKit handle may be stale after sleep.
            do {
                try self.connection.reconnect()
            } catch {
                // Surface the condition but keep retrying — never leave polling dead.
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.errorLog?.setCondition(
                        id: "smc.disconnected",
                        message: "SMC connection lost after wake (\(error.localizedDescription)) — retrying",
                        source: .smc, severity: .critical
                    )
                }
                self.reconnectAfterWake(attempt: attempt + 1)
                return
            }
            reader.clearCache()

            // The SMC may report 0 fans briefly while it settles — fast-retry a couple
            // of times, then resume polling regardless so temperatures keep flowing.
            let fanCount = (try? reader.fanCount()) ?? 0
            if fanCount == 0 && attempt < 2 {
                self.reconnectAfterWake(attempt: attempt + 1)
                return
            }

            let fanModels = (0..<fanCount).map { Fan(index: $0) }
            if !fanModels.isEmpty {
                self.workingFans = fanModels
                self.publishedFans = fanModels
            }
            // Reset so static fan data (min/max) is read on next poll
            self.pollCount = 0
            self.consecutiveReadFailures = 0
            self.isReconnecting = false

            DispatchQueue.main.async {
                self.isConnected = true
                self.errorLog?.clearCondition(id: "smc.disconnected")
                self.errorLog?.clearCondition(id: "smc.reads_failing")
                if fanModels.isEmpty {
                    self.errorLog?.setCondition(
                        id: "smc.no_fans",
                        message: "No fans detected after wake",
                        source: .smc, severity: .critical
                    )
                } else {
                    self.fans = fanModels
                    self.errorLog?.clearCondition(id: "smc.no_fans")
                }
            }

            self.schedulePollTimer()
            self.poll()
        }
    }

    private func discoverSensors(attempt: Int = 0) {
        smcQueue.async { [weak self] in
            guard let self, let reader = self.reader else { return }

            let sensors = (try? reader.discoverTemperatureSensors()) ?? []
            let fanCount = (try? reader.fanCount()) ?? 0

            // Retry if SMC returned 0 fans (may still be initializing after wake)
            if fanCount == 0 && attempt < 3 {
                self.smcQueue.asyncAfter(deadline: .now() + 2.0) {
                    self.discoverSensors(attempt: attempt + 1)
                }
                return
            }

            let tempModels = sensors.map {
                TemperatureSensor(key: $0.key, name: $0.name, value: $0.value)
            }
            let fanModels = (0..<fanCount).map { Fan(index: $0) }

            // Seed the serial-owned working set before the timer starts.
            self.workingTemps = tempModels
            self.workingFans = fanModels
            self.publishedTemps = tempModels
            self.publishedFans = fanModels
            self.pollCount = 0
            self.consecutiveReadFailures = 0

            let names = Dictionary(uniqueKeysWithValues: tempModels.map { ($0.key, $0.name) })

            DispatchQueue.main.async {
                self.sensorNames = names
                self.updateSummaryTemps(tempModels)
                self.temperatures = tempModels
                self.fans = fanModels

                if fanCount == 0 {
                    self.errorLog?.setCondition(
                        id: "smc.no_fans",
                        message: "No fans detected after \(attempt + 1) attempts",
                        source: .smc, severity: .critical
                    )
                } else {
                    self.errorLog?.clearCondition(id: "smc.no_fans")
                }
            }

            self.schedulePollTimer()
            self.poll()
        }
    }

    /// (Re)create the poll timer on smcQueue. Always cancels the previous source first,
    /// so it can never leak or double-schedule.
    private func schedulePollTimer() {
        dispatchPrecondition(condition: .onQueue(smcQueue))
        pollTimer?.cancel()
        let interval = currentInterval
        let timer = DispatchSource.makeTimerSource(queue: smcQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval,
                       leeway: .milliseconds(Int(interval * 300)))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        pollTimer = timer
    }

    private func poll() {
        dispatchPrecondition(condition: .onQueue(smcQueue))
        guard let reader else { return }
        var pollErrors: [String] = []

        // CPU (TC*) and GPU (TG*) sensors drive the summary cards, default fan curves,
        // and the typical charted sensors — keep those at 1 Hz. Every 5th tick we also
        // refresh the rest so the sidebar stays current.
        let refreshAllSensors = (pollCount % 5 == 0)
        for i in workingTemps.indices {
            let key = workingTemps[i].key
            let isHotTier = key.hasPrefix("TC") || key.hasPrefix("TG")
            guard isHotTier || refreshAllSensors else { continue }
            do {
                workingTemps[i].value = try reader.readTemperature(key: FourCharCode(key))
            } catch {
                pollErrors.append("\(key): \(error.localizedDescription)")
            }
        }

        // Read fan data (min/max are static — only refresh every 60 polls)
        let readStaticFanData = (pollCount % 60 == 0) || pollCount <= 2
        for i in workingFans.indices {
            let idx = workingFans[i].index
            do {
                workingFans[i].actualRPM = try reader.fanActualSpeed(fanIndex: idx)
            } catch {
                pollErrors.append("Fan \(idx) speed: \(error.localizedDescription)")
            }
            if readStaticFanData {
                do {
                    workingFans[i].minRPM = try reader.fanMinSpeed(fanIndex: idx)
                    workingFans[i].maxRPM = try reader.fanMaxSpeed(fanIndex: idx)
                } catch {
                    pollErrors.append("Fan \(idx) range: \(error.localizedDescription)")
                }
            }
            do {
                let (_, bytes) = try reader.readKey(SMCKey.fanTarget(idx))
                workingFans[i].targetRPM = Double(flt: bytes)
            } catch {
                // Target RPM is non-critical, don't add to pollErrors
            }
        }

        pollCount += 1
        let isFirstPoll = pollCount <= 2

        // Compute publish deltas against what the UI currently shows.
        let tempsChanged = isFirstPoll
            || publishedTemps.count != workingTemps.count
            || zip(publishedTemps, workingTemps).contains { abs($0.value - $1.value) >= 1.0 }
        let fansChanged = isFirstPoll
            || publishedFans.count != workingFans.count
            || zip(publishedFans, workingFans).contains { abs($0.actualRPM - $1.actualRPM) >= 50.0 }
        if tempsChanged { publishedTemps = workingTemps }
        if fansChanged { publishedFans = workingFans }

        // Failure counting stays on smcQueue; the side effects fire on main.
        let justCleared: Bool
        if pollErrors.isEmpty {
            justCleared = consecutiveReadFailures > 0
            consecutiveReadFailures = 0
        } else {
            justCleared = false
            consecutiveReadFailures += 1
        }
        let failures = consecutiveReadFailures

        let temps = workingTemps
        let fans = workingFans
        DispatchQueue.main.async { [weak self] in
            self?.publishPoll(temps: temps, fans: fans,
                              tempsChanged: tempsChanged, fansChanged: fansChanged,
                              pollErrors: pollErrors, failures: failures, justCleared: justCleared)
        }
    }

    /// The single point where @Published state is written — always on main.
    private func publishPoll(temps: [TemperatureSensor], fans: [Fan],
                             tempsChanged: Bool, fansChanged: Bool,
                             pollErrors: [String], failures: Int, justCleared: Bool) {
        if tempsChanged {
            updateSummaryTemps(temps)
            temperatures = temps
        }
        if fansChanged {
            self.fans = fans
        }

        // Keep chart history at poll cadence now that the visible window is short.
        if isCollectingHistory {
            appendHistory(temps)
        }

        let newLabel = formatMenuBarLabel(temps)
        if newLabel != menuBarLabel {
            menuBarLabel = newLabel
        }

        // Curve engine and notifications only care about temps.
        if tempsChanged {
            onPoll?(temps)
        }
        // Always-fires heartbeat for samplers that don't depend on temp changes.
        onPollAlways?()

        // Error reporting / safety escalation.
        if pollErrors.isEmpty {
            if justCleared {
                errorLog?.clearCondition(id: "smc.reads_failing")
            }
        } else {
            if failures == 3 {
                for msg in Set(pollErrors) {
                    errorLog?.logTransient(msg, source: .smc)
                }
            }
            if failures == 15 {
                errorLog?.setCondition(
                    id: "smc.reads_failing",
                    message: "SMC sensor reads are consistently failing",
                    source: .smc, severity: .warning
                )
            }
            if failures == 30 {
                errorLog?.setCondition(
                    id: "smc.reads_failing",
                    message: "SMC unresponsive for 30s — restoring automatic fan control",
                    source: .smc, severity: .critical
                )
                onSafetyRestore?()
            }
        }
    }

    private func appendHistory(_ sensors: [TemperatureSensor]) {
        let now = Date()
        let cutoff = now.addingTimeInterval(-maxHistoryDuration)
        readingCounter += 1
        for sensor in sensors {
            var readings = _fullHistory[sensor.key] ?? []
            readings.append(TemperatureReading(id: readingCounter, date: now, value: sensor.value))

            if let firstRetainedIndex = readings.firstIndex(where: { $0.date >= cutoff }) {
                if firstRetainedIndex > 0 {
                    readings.removeFirst(firstRetainedIndex)
                }
            } else if !readings.isEmpty {
                readings = Array(readings.suffix(1))
            }

            _fullHistory[sensor.key] = readings
        }
        chartHistory = _fullHistory
    }

    private func formatMenuBarLabel(_ sensors: [TemperatureSensor]) -> String {
        let cpuTemp = sensors.first(where: { $0.key == "TCXC" })?.value
            ?? sensors.filter({ $0.key.hasPrefix("TC") }).map(\.value).max()
            ?? 0
        return String(format: "%.0f°C", cpuTemp)
    }
}
