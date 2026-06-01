import Foundation

/// NSXPCListener delegate that validates incoming connections and vends the fan control service.
final class FanControlDelegate: NSObject, NSXPCListenerDelegate {
    /// One shared service across all connections, so forced-fan state and (later) the
    /// safety loop are consistent regardless of how many clients connect.
    private let service = FanControlServiceImpl()

    /// Only our own app may drive the root helper. setCodeSigningRequirement (macOS 13+)
    /// validates the peer against this requirement using its AUDIT TOKEN — the
    /// audit-token-safe replacement for the old, racy PID-based check (a PID can be
    /// reused/spoofed in the validation window; the audit token cannot).
    ///
    /// This is identifier-only because the app is ad-hoc signed (local, non-distributed
    /// build). It blocks every process that isn't signed as com.tomsfans.app — i.e. all
    /// generic local processes. A determined local attacker could ad-hoc-sign a binary
    /// with this identifier; anchoring to a self-signed certificate would close that
    /// remaining gap. Adequate for a personal build.
    private static let clientRequirement = #"identifier "com.tomsfans.app""#

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Reject any caller that isn't our app, by audit token.
        connection.setCodeSigningRequirement(Self.clientRequirement)

        connection.exportedInterface = NSXPCInterface(with: FanControlProtocol.self)
        connection.exportedObject = service
        let service = self.service
        connection.invalidationHandler = {
            // The app's connection dropped — clean quit OR crash/kill. We can't tell
            // which, so hand fans back to firmware (macOS will NOT raise a forced-low
            // fan on its own — docs/thermal-safety-findings.md) and resume any throttled
            // process so a duty-cycle throttle never outlives the controller.
            service.emergencyRestore()
            service.emergencyResumeThrottles()
        }
        connection.resume()
        return true
    }
}
