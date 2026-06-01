import Foundation

/// App-side XPC client that communicates with the privileged helper to control fans.
final class XPCFanControlService: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?

    /// Whether the installed helper matches the version this app build expects.
    /// Updated on every (re)connect by probing `getHelperVersion()`.
    @Published private(set) var helperVersionStatus: HelperVersionStatus = .unknown

    var errorLog: ErrorLog?
    var onDisconnect: (() -> Void)?
    private var xpcConnection: NSXPCConnection?

    /// Guard sensor the helper watches while fans are forced.
    /// TCXC = Intel CPU package (PECI). TODO(#7): branch sensor for Apple Silicon.
    private static let thermalGuardSensor = "TCXC"

    /// Thermal-guard config, mirrored from AppSettings (set at bootstrap and on change).
    var thermalLockoutEnabled = true
    var thermalCeilingC: Double = ThermalCeiling.defaultC

    /// Get a proxy to the helper's FanControlProtocol.
    /// Lazily creates the XPC connection on first access.
    var proxy: FanControlProtocol? {
        if xpcConnection == nil { connect() }
        return xpcConnection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            DispatchQueue.main.async {
                self?.isConnected = false
                self?.lastError = error.localizedDescription
                self?.xpcConnection = nil
                self?.errorLog?.setCondition(
                    id: "xpc.disconnected",
                    message: "Helper connection lost: \(error.localizedDescription)",
                    source: .xpc, severity: .critical
                )
                self?.onDisconnect?()
            }
        } as? FanControlProtocol
    }

    func connect() {
        guard xpcConnection == nil else { return }
        let conn = NSXPCConnection(machServiceName: XPCConstants.machServiceName,
                                   options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: FanControlProtocol.self)
        conn.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.isConnected = false
                self?.xpcConnection = nil
                self?.helperVersionStatus = .unknown
                self?.onDisconnect?()
            }
        }
        conn.resume()
        xpcConnection = conn
        isConnected = true
        lastError = nil
        errorLog?.clearCondition(id: "xpc.disconnected")
        verifyHelperVersion()
    }

    func disconnect() {
        xpcConnection?.invalidate()
        xpcConnection = nil
        isConnected = false
        helperVersionStatus = .unknown
    }

    /// Drop any existing connection and reconnect, re-probing the helper version.
    /// Used after reinstalling the helper so the UI reflects the freshly loaded binary.
    func reconnectAndVerify() {
        disconnect()
        connect()
    }

    /// Probe the running helper's version and compare it to the version this app build
    /// expects (`XPCConstants.helperVersion`). A mismatch means an old helper is still
    /// running after an app update; we surface it as a condition for the UI to act on.
    func verifyHelperVersion() {
        proxy?.getHelperVersion { [weak self] reported in
            DispatchQueue.main.async {
                guard let self else { return }
                let status = HelperVersionCheck.evaluate(installed: reported,
                                                         expected: XPCConstants.helperVersion)
                self.helperVersionStatus = status
                switch status {
                case .mismatched(let installed, let expected):
                    self.errorLog?.setCondition(
                        id: "helper.versionMismatch",
                        message: "Installed helper is \(installed); this app expects \(expected). Update the helper.",
                        source: .xpc, severity: .warning
                    )
                case .matched, .unknown:
                    self.errorLog?.clearCondition(id: "helper.versionMismatch")
                }
            }
        }
    }

    /// Convenience: set fan speed and update state on completion.
    func setFanMinSpeed(fanIndex: Int, rpm: Int) {
        proxy?.setFanMinSpeed(fanIndex: fanIndex, rpm: rpm) { [weak self] success, error in
            if !success {
                let msg = error ?? "Failed to set fan \(fanIndex) speed"
                DispatchQueue.main.async {
                    self?.lastError = msg
                    self?.errorLog?.logTransient(msg, source: .xpc)
                }
            }
        }
    }

    /// Convenience: set fan mode (0 = auto, 1 = forced).
    func setFanMode(fanIndex: Int, mode: UInt8) {
        // Arm (or, if disabled, clear) the helper's thermal failsafe when we take forced control.
        if mode == 1 {
            updateThermalGuard()
        }
        proxy?.setFanMode(fanIndex: fanIndex, mode: mode) { [weak self] success, error in
            if !success {
                let msg = error ?? "Failed to set fan \(fanIndex) mode"
                DispatchQueue.main.async {
                    self?.lastError = msg
                    self?.errorLog?.logTransient(msg, source: .xpc)
                }
            }
        }
    }

    /// Push the current thermal-guard config to the helper. A ceiling of 0 disables
    /// the guard (and clears any standing lockout) helper-side. Call when the user
    /// changes the setting while fans are already forced.
    func updateThermalGuard() {
        let ceiling = thermalLockoutEnabled ? thermalCeilingC : 0
        proxy?.setThermalGuard(sensorKey: Self.thermalGuardSensor, ceilingC: ceiling) { _, _ in }
    }

    /// Convenience: restore all fans to automatic control.
    func restoreAutomatic() {
        // Disarm the thermal failsafe — we're handing control back to the OS.
        proxy?.setThermalGuard(sensorKey: "", ceilingC: 0) { _, _ in }
        proxy?.restoreAutomaticControl { [weak self] success, error in
            if !success {
                let msg = error ?? "Failed to restore automatic fan control"
                DispatchQueue.main.async {
                    self?.lastError = msg
                    self?.errorLog?.logTransient(msg, source: .xpc)
                }
            }
        }
    }

    /// Begin helper-owned duty-cycle throttling of a PID (level = fraction suspended).
    func startThrottle(pid: pid_t, level: Double) {
        proxy?.startThrottle(pid: pid, level: level) { [weak self] success, error in
            if !success, let error {
                DispatchQueue.main.async { self?.errorLog?.logTransient(error, source: .process) }
            }
        }
    }

    /// Stop throttling a PID (the helper guarantees it is resumed).
    func stopThrottle(pid: pid_t) {
        proxy?.stopThrottle(pid: pid) { _, _ in }
    }

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
}
