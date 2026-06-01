import Foundation
import ServiceManagement

/// Manages installation and status of the privileged helper daemon.
final class HelperInstallService: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notFound
    @Published private(set) var lastError: String?

    private let service = SMAppService.daemon(plistName: "com.tomsfans.helper.plist")

    init() {
        refreshStatus()
    }

    func register() {
        do {
            try service.register()
            refreshStatus()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            refreshStatus()
        }
    }

    func unregister() {
        do {
            try service.unregister()
            refreshStatus()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            refreshStatus()
        }
    }

    func refreshStatus() {
        status = service.status
    }

    var statusDescription: String {
        switch status {
        case .notRegistered:
            return "Not Registered"
        case .enabled:
            return "Enabled"
        case .requiresApproval:
            return "Requires Approval in System Settings"
        case .notFound:
            return "Not Found"
        @unknown default:
            return "Unknown"
        }
    }

    var isHelperRunning: Bool {
        status == .enabled
    }

    var needsApproval: Bool {
        status == .requiresApproval
    }
}
