import Foundation

/// App-side XPC client that communicates with the privileged helper to control fans.
final class XPCFanControlService: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?

    var errorLog: ErrorLog?
    var onDisconnect: (() -> Void)?
    private var xpcConnection: NSXPCConnection?

    /// Absolute CPU thermal ceiling the helper enforces while fans are forced.
    /// TCXC = Intel CPU package (PECI). TODO(#7): branch sensor for Apple Silicon;
    /// TODO: make the ceiling user-configurable in Settings.
    private static let thermalGuardSensor = "TCXC"
    private static let thermalGuardCeilingC: Double = 90

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
        let conn = NSXPCConnection(machServiceName: XPCConstants.machServiceName,
                                   options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: FanControlProtocol.self)
        conn.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.isConnected = false
                self?.xpcConnection = nil
                self?.onDisconnect?()
            }
        }
        conn.resume()
        xpcConnection = conn
        isConnected = true
        lastError = nil
        errorLog?.clearCondition(id: "xpc.disconnected")
    }

    func disconnect() {
        xpcConnection?.invalidate()
        xpcConnection = nil
        isConnected = false
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
        // Arm the helper's thermal failsafe whenever we take forced control.
        if mode == 1 {
            proxy?.setThermalGuard(sensorKey: Self.thermalGuardSensor,
                                   ceilingC: Self.thermalGuardCeilingC) { _, _ in }
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
