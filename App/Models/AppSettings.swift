import Foundation
import ServiceManagement

enum CPUDisplayMode: String, CaseIterable, Identifiable {
    case raw1600 = "raw"
    case normalized100 = "normalized"
    var id: String { rawValue }
}

enum TemperatureHistoryRange: Int, CaseIterable, Identifiable {
    case oneMinute = 60
    case threeMinutes = 180
    case fiveMinutes = 300

    var id: Self { self }

    var duration: TimeInterval {
        TimeInterval(rawValue)
    }

    var title: String {
        switch self {
        case .oneMinute: "1m"
        case .threeMinutes: "3m"
        case .fiveMinutes: "5m"
        }
    }

    var axisTickInterval: TimeInterval {
        switch self {
        case .oneMinute: 15
        case .threeMinutes: 30
        case .fiveMinutes: 60
        }
    }

    static var maximumDuration: TimeInterval {
        TimeInterval(allCases.map(\.rawValue).max() ?? oneMinute.rawValue)
    }
}

final class AppSettings: ObservableObject {
    @Published var presets: [FanPreset] {
        didSet { debouncedSave("presets", presets) }
    }
    @Published var fanCurves: [FanCurve] {
        didSet { debouncedSave("fanCurves", fanCurves) }
    }
    @Published var alertThresholds: [String: Double] {
        didSet { debouncedSave("alertThresholds", alertThresholds) }
    }
    @Published var controlMode: FanControlMode {
        didSet { UserDefaults.standard.set(controlMode.rawValue, forKey: "controlMode") }
    }
    @Published var activePresetId: UUID? {
        didSet {
            if let id = activePresetId {
                UserDefaults.standard.set(id.uuidString, forKey: "activePresetId")
            } else {
                UserDefaults.standard.removeObject(forKey: "activePresetId")
            }
        }
    }
    @Published var activeCurveId: UUID? {
        didSet {
            if let id = activeCurveId {
                UserDefaults.standard.set(id.uuidString, forKey: "activeCurveId")
            } else {
                UserDefaults.standard.removeObject(forKey: "activeCurveId")
            }
        }
    }
    @Published var pollInterval: TimeInterval {
        didSet { UserDefaults.standard.set(pollInterval, forKey: "pollInterval") }
    }
    @Published var temperatureHistoryRange: TemperatureHistoryRange {
        didSet { UserDefaults.standard.set(temperatureHistoryRange.rawValue, forKey: "temperatureHistoryRange") }
    }
    @Published var showTemperatureInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showTemperatureInMenuBar, forKey: "showTempMenuBar") }
    }
    @Published var temperatureUnit: TemperatureUnit {
        didSet { UserDefaults.standard.set(temperatureUnit.rawValue, forKey: "tempUnit") }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            toggleLaunchAtLogin()
        }
    }
    @Published var processMonitoringEnabled: Bool {
        didSet { UserDefaults.standard.set(processMonitoringEnabled, forKey: "processMonitoringEnabled") }
    }
    @Published var remediationEnabled: Bool {
        didSet { UserDefaults.standard.set(remediationEnabled, forKey: "remediationEnabled") }
    }
    @Published var cpuDisplayMode: CPUDisplayMode {
        didSet { UserDefaults.standard.set(cpuDisplayMode.rawValue, forKey: "cpuDisplayMode") }
    }

    enum TemperatureUnit: String, CaseIterable, Identifiable {
        case celsius, fahrenheit
        var id: String { rawValue }
    }

    // Debounce timers for expensive JSON saves
    private var saveTimers: [String: Timer] = [:]
    private var isUpdatingLaunchAtLogin = false

    init() {
        // Migrate old fan curve format (v1 used "rpm", v2 uses "percent")
        if UserDefaults.standard.integer(forKey: "fanCurveVersion") < 2 {
            UserDefaults.standard.removeObject(forKey: "fanCurves")
            UserDefaults.standard.removeObject(forKey: "activeCurveId")
            UserDefaults.standard.set(2, forKey: "fanCurveVersion")
        }

        self.presets = Self.load("presets") ?? FanPreset.defaultPresets
        self.fanCurves = Self.load("fanCurves") ?? [FanCurve.defaultCurve]
        self.alertThresholds = Self.load("alertThresholds") ?? ["TCXC": 95, "TG0P": 90]
        self.controlMode = FanControlMode(rawValue:
            UserDefaults.standard.string(forKey: "controlMode") ?? "automatic") ?? .automatic
        self.activePresetId = UserDefaults.standard.string(forKey: "activePresetId")
            .flatMap { UUID(uuidString: $0) }
        self.activeCurveId = UserDefaults.standard.string(forKey: "activeCurveId")
            .flatMap { UUID(uuidString: $0) }
        let stored = UserDefaults.standard.double(forKey: "pollInterval")
        self.pollInterval = stored > 0 ? stored : 1.0
        self.temperatureHistoryRange = TemperatureHistoryRange(
            rawValue: UserDefaults.standard.integer(forKey: "temperatureHistoryRange")
        ) ?? .oneMinute
        self.showTemperatureInMenuBar = UserDefaults.standard.object(forKey: "showTempMenuBar") as? Bool ?? true
        self.temperatureUnit = TemperatureUnit(rawValue:
            UserDefaults.standard.string(forKey: "tempUnit") ?? "celsius") ?? .celsius
        self.launchAtLogin = false
        self.processMonitoringEnabled = (UserDefaults.standard.object(forKey: "processMonitoringEnabled") as? Bool) ?? true
        self.remediationEnabled = (UserDefaults.standard.object(forKey: "remediationEnabled") as? Bool) ?? false
        self.cpuDisplayMode = CPUDisplayMode(rawValue:
            UserDefaults.standard.string(forKey: "cpuDisplayMode") ?? "normalized") ?? .normalized100
        refreshLaunchAtLoginState()

        // Persist default fan curves if they were just created (init doesn't trigger didSet)
        if UserDefaults.standard.data(forKey: "fanCurves") == nil {
            UserDefaults.standard.set(try? JSONEncoder().encode(fanCurves), forKey: "fanCurves")
        }
    }

    private func toggleLaunchAtLogin() {
        guard !isUpdatingLaunchAtLogin else { return }
        isUpdatingLaunchAtLogin = true
        defer { isUpdatingLaunchAtLogin = false }

        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            // Revert to actual state without re-triggering didSet loop
            let actualState = SMAppService.mainApp.status == .enabled
            if launchAtLogin != actualState {
                isUpdatingLaunchAtLogin = true
                launchAtLogin = actualState
                isUpdatingLaunchAtLogin = false
            }
        }
    }

    func refreshLaunchAtLoginState() {
        let actualState = SMAppService.mainApp.status == .enabled
        if launchAtLogin != actualState {
            isUpdatingLaunchAtLogin = true
            launchAtLogin = actualState
            isUpdatingLaunchAtLogin = false
        }
    }

    /// Debounced save — waits 0.5s after last change before writing JSON to disk.
    private func debouncedSave<T: Encodable>(_ key: String, _ value: T) {
        saveTimers[key]?.invalidate()
        saveTimers[key] = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
        }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
