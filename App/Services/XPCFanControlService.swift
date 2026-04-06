import Foundation

/// App-side XPC client that communicates with the privileged helper to control fans.
final class XPCFanControlService: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?

    var errorLog: ErrorLog?
    var onDisconnect: (() -> Void)?
    private var xpcConnection: NSXPCConnection?

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
}
