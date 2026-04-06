import Foundation
import IOKit

struct TemperatureReading: Identifiable, Equatable {
    let id: Int  // Sequential counter, not UUID (avoids allocation)
    let date: Date
    let value: Double
}

/// Polls SMC sensors on a timer, publishes state for the UI.
/// Optimized to only trigger @Published when values meaningfully change.
final class SMCMonitorService: ObservableObject {
    @Published var temperatures: [TemperatureSensor] = []
    @Published var fans: [Fan] = []
    @Published var chartHistory: [String: [TemperatureReading]] = [:]
    private var _fullHistory: [String: [TemperatureReading]] = [:]
    @Published var menuBarLabel: String = "--°C"
    @Published var isConnected = false
    private(set) var sensorNames: [String: String] = [:]

    private var reader: SMCReader?
    private let connection = SMCConnection()
    private var timer: Timer?
    private var pollInterval: TimeInterval = 1.0
    private var currentInterval: TimeInterval = 1.0
    private let idlePollInterval: TimeInterval = 5.0
    private let maxHistoryDuration = TemperatureHistoryRange.maximumDuration
    private var readingCounter = 0
    private var pollCount = 0
    private var consecutiveReadFailures = 0

    var errorLog: ErrorLog?
    var onSafetyRestore: (() -> Void)?
    var isCollectingHistory = true

    func clearHistory() {
        _fullHistory.removeAll()
        chartHistory.removeAll()
    }

    var onPoll: (([TemperatureSensor]) -> Void)?

    // MARK: - Cached Summary Temps (updated during poll, no allocations on read)

    private(set) var cpuPackageTemp: Double = 0
    private(set) var gpuTemp: Double = 0

    private func updateSummaryTemps(_ sensors: [TemperatureSensor]) {
        cpuPackageTemp = sensors.first(where: { $0.key == "TCXC" })?.value
            ?? sensors.filter({ $0.key.hasPrefix("TC") }).map(\.value).max()
            ?? 0
        gpuTemp = sensors.first(where: { $0.key == "TG0P" })?.value ?? 0
    }

    init() {
        do {
            try connection.open()
            reader = SMCReader(connection: connection)
            isConnected = true
            discoverSensors()
            startPolling()
        } catch {
            isConnected = false
        }
    }

    deinit {
        timer?.invalidate()
        connection.close()
    }

    func updatePollInterval(_ interval: TimeInterval) {
        guard interval != pollInterval, interval > 0 else { return }
        pollInterval = interval
        // Only restart if we're using the active rate
        if currentInterval != idlePollInterval {
            currentInterval = interval
            timer?.invalidate()
            startPolling()
        }
    }

    func pausePolling() {
        timer?.invalidate()
        timer = nil
    }

    func resumePolling() {
        guard timer == nil else { return }
        reconnectAfterWake()
    }

    private func reconnectAfterWake(attempt: Int = 0) {
        let delay: TimeInterval = attempt == 0 ? 1.0 : 2.0
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let reader = self.reader else { return }

            // Reconnect — IOKit handle may be stale after sleep
            do {
                try self.connection.reconnect()
            } catch {
                if attempt < 2 {
                    self.reconnectAfterWake(attempt: attempt + 1)
                } else {
                    DispatchQueue.main.async {
                        self.isConnected = false
                        self.errorLog?.setCondition(
                            id: "smc.disconnected",
                            message: "SMC connection lost after wake (\(error.localizedDescription))",
                            source: .smc, severity: .critical
                        )
                    }
                }
                return
            }
            reader.clearCache()

            // Re-discover fans (SMC may need a moment post-wake)
            let fanCount = (try? reader.fanCount()) ?? 0
            if fanCount == 0 && attempt < 2 {
                self.reconnectAfterWake(attempt: attempt + 1)
                return
            }

            let fanModels = (0..<fanCount).map { Fan(index: $0) }

            DispatchQueue.main.async {
                self.isConnected = true
                self.errorLog?.clearCondition(id: "smc.disconnected")
                self.errorLog?.clearCondition(id: "smc.reads_failing")
                if !fanModels.isEmpty {
                    self.fans = fanModels
                    self.errorLog?.clearCondition(id: "smc.no_fans")
                }
                // Reset so static fan data (min/max) is read on next poll
                self.pollCount = 0
                self.consecutiveReadFailures = 0
                self.startPolling()
                self.poll()
            }
        }
    }

    func setIdleMode(_ idle: Bool) {
        let target = idle ? idlePollInterval : pollInterval
        guard target != currentInterval else { return }
        currentInterval = target
        timer?.invalidate()
        startPolling()
    }

    // MARK: - Private

    private func discoverSensors(attempt: Int = 0) {
        guard let reader else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let sensors = (try? reader.discoverTemperatureSensors()) ?? []
            let fanCount = (try? reader.fanCount()) ?? 0

            // Retry if SMC returned 0 fans (may still be initializing after wake)
            if fanCount == 0 && attempt < 3 {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) {
                    self.discoverSensors(attempt: attempt + 1)
                }
                return
            }

            let tempModels = sensors.map {
                TemperatureSensor(key: $0.key, name: $0.name, value: $0.value)
            }
            let fanModels = (0..<fanCount).map { Fan(index: $0) }

            DispatchQueue.main.async {
                self.sensorNames = Dictionary(uniqueKeysWithValues: tempModels.map { ($0.key, $0.name) })
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

                self.poll()
            }
        }
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer?.tolerance = currentInterval * 0.3
    }

    private func poll() {
        guard let reader else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var pollErrors: [String] = []

            // Read temperatures
            var updatedTemps = self.temperatures
            for i in updatedTemps.indices {
                do {
                    updatedTemps[i].value = try reader.readTemperature(key: FourCharCode(updatedTemps[i].key))
                } catch {
                    pollErrors.append("\(updatedTemps[i].key): \(error.localizedDescription)")
                }
            }

            // Read fan data (min/max are static — only refresh every 60 polls)
            let readStaticFanData = (self.pollCount % 60 == 0) || self.pollCount <= 2
            var updatedFans = self.fans
            for i in updatedFans.indices {
                let idx = updatedFans[i].index
                do {
                    updatedFans[i].actualRPM = try reader.fanActualSpeed(fanIndex: idx)
                } catch {
                    pollErrors.append("Fan \(idx) speed: \(error.localizedDescription)")
                }
                if readStaticFanData {
                    do {
                        updatedFans[i].minRPM = try reader.fanMinSpeed(fanIndex: idx)
                        updatedFans[i].maxRPM = try reader.fanMaxSpeed(fanIndex: idx)
                    } catch {
                        pollErrors.append("Fan \(idx) range: \(error.localizedDescription)")
                    }
                }
                do {
                    let (_, bytes) = try reader.readKey(SMCKey.fanTarget(idx))
                    updatedFans[i].targetRPM = Double(flt: bytes)
                } catch {
                    // Target RPM is non-critical, don't add to pollErrors
                }
            }

            DispatchQueue.main.async {
                self.pollCount += 1
                let isFirstPoll = self.pollCount <= 2

                // Only publish temperatures if any sensor changed by >= 1°C
                // Always publish on first polls to ensure UI gets initial data
                let tempsChanged = isFirstPoll
                    || self.temperatures.count != updatedTemps.count
                    || zip(self.temperatures, updatedTemps).contains { abs($0.value - $1.value) >= 1.0 }
                if tempsChanged {
                    self.updateSummaryTemps(updatedTemps)
                    self.temperatures = updatedTemps
                }

                // Only publish fans when any RPM changed by >= 50
                let fansChanged = isFirstPoll
                    || self.fans.count != updatedFans.count
                    || zip(self.fans, updatedFans).contains { abs($0.actualRPM - $1.actualRPM) >= 50.0 }
                if fansChanged {
                    self.fans = updatedFans
                }

                // Keep chart history at poll cadence now that the visible window is short.
                if self.isCollectingHistory {
                    self.appendHistory(updatedTemps)
                }

                // Only update menu bar label if string actually changed
                let newLabel = self.formatMenuBarLabel(updatedTemps)
                if newLabel != self.menuBarLabel {
                    self.menuBarLabel = newLabel
                }

                // Only invoke poll callback when temperatures changed —
                // curve engine and notifications only care about temps
                if tempsChanged {
                    self.onPoll?(updatedTemps)
                }

                // Track consecutive read failures for error reporting
                if pollErrors.isEmpty {
                    if self.consecutiveReadFailures > 0 {
                        self.consecutiveReadFailures = 0
                        self.errorLog?.clearCondition(id: "smc.reads_failing")
                    }
                } else {
                    self.consecutiveReadFailures += 1
                    if self.consecutiveReadFailures == 3 {
                        for msg in Set(pollErrors) {
                            self.errorLog?.logTransient(msg, source: .smc)
                        }
                    }
                    if self.consecutiveReadFailures == 15 {
                        self.errorLog?.setCondition(
                            id: "smc.reads_failing",
                            message: "SMC sensor reads are consistently failing",
                            source: .smc, severity: .warning
                        )
                    }
                    if self.consecutiveReadFailures == 30 {
                        self.errorLog?.setCondition(
                            id: "smc.reads_failing",
                            message: "SMC unresponsive for 30s — restoring automatic fan control",
                            source: .smc, severity: .critical
                        )
                        self.onSafetyRestore?()
                    }
                }
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
