import AppKit
import Combine
import SwiftUI
import UserNotifications

@main
struct TomsFansApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var monitor = SMCMonitorService()
    @StateObject private var fanControl = XPCFanControlService()
    @StateObject private var helperInstall = HelperInstallService()
    @StateObject private var curveEngine = FanCurveEngine()
    @StateObject private var settings = AppSettings()
    @StateObject private var notifications = NotificationService()
    @StateObject private var errorLog = ErrorLog()

    var body: some Scene {
        Window("Tom's Fans", id: "main") {
            ContentView()
                .environmentObject(monitor)
                .environmentObject(fanControl)
                .environmentObject(helperInstall)
                .environmentObject(curveEngine)
                .environmentObject(settings)
                .environmentObject(notifications)
                .environmentObject(errorLog)
                .onAppear {
                    bootstrapIfNeeded()
                    monitor.isCollectingHistory = true
                    monitor.setIdleMode(false)
                    NSApp.setActivationPolicy(.regular)
                }
                .onDisappear {
                    monitor.isCollectingHistory = false
                    monitor.clearHistory()
                    monitor.setIdleMode(true)
                    NSApp.setActivationPolicy(.accessory)
                    if !AppDelegate.isTerminating {
                        sendMenuBarNotification()
                    }
                }
        }
        .defaultSize(width: 900, height: 650)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(monitor)
                .environmentObject(fanControl)
                .environmentObject(settings)
                .environmentObject(errorLog)
                .onAppear {
                    // Also wire up here in case window wasn't opened
                    bootstrapIfNeeded()
                }
        } label: {
            Text(monitor.menuBarLabel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(helperInstall)
                .environmentObject(notifications)
                .environmentObject(errorLog)
        }
    }

    private static var hasBootstrapped = false
    private static var cancellables: Set<AnyCancellable> = []

    private func bootstrapIfNeeded() {
        guard !Self.hasBootstrapped else { return }
        Self.hasBootstrapped = true
        monitor.errorLog = errorLog
        fanControl.errorLog = errorLog
        curveEngine.errorLog = errorLog
        monitor.updatePollInterval(settings.pollInterval)
        setupPollCallback()
        setupSafetyCallbacks()
        notifications.setup()
        reapplySavedMode()
        observePollIntervalChanges()
        observeSleepWake()
    }

    private func observePollIntervalChanges() {
        settings.$pollInterval
            .dropFirst()
            .sink { [weak monitor] interval in
                monitor?.updatePollInterval(interval)
            }
            .store(in: &Self.cancellables)
    }

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter

        center.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak fanControl, weak curveEngine, weak monitor] _ in
                fanControl?.restoreAutomatic()
                curveEngine?.reset()
                monitor?.pausePolling()
            }
            .store(in: &Self.cancellables)

        center.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak monitor, weak fanControl, weak curveEngine, weak settings] _ in
                monitor?.resumePolling()
                guard let settings, let fanControl else { return }
                reapplyMode(settings: settings, fanControl: fanControl, curveEngine: curveEngine)
            }
            .store(in: &Self.cancellables)
    }

    private func setupPollCallback() {
        monitor.onPoll = { [weak curveEngine, weak settings, weak fanControl, weak monitor, weak notifications] temps in
            guard let settings, let fanControl else { return }

            if settings.controlMode == .fanCurve {
                let curve = settings.fanCurves.first(where: { $0.id == settings.activeCurveId })
                    ?? settings.fanCurves.first
                if let curve {
                    if settings.activeCurveId != curve.id {
                        settings.activeCurveId = curve.id
                    }
                    curveEngine?.evaluate(curve: curve, temperatures: temps,
                                          fans: monitor?.fans ?? [], fanControl: fanControl)
                }
            }

            notifications?.checkThresholds(temperatures: temps, thresholds: settings.alertThresholds)
        }
    }

    private func setupSafetyCallbacks() {
        let restore = { [weak fanControl, weak curveEngine, weak settings] in
            guard let settings, let fanControl else { return }
            guard settings.controlMode != .automatic else { return }
            settings.controlMode = .automatic
            curveEngine?.reset()
            fanControl.restoreAutomatic()
        }
        monitor.onSafetyRestore = restore
        curveEngine.onSafetyRestore = restore
        fanControl.onDisconnect = restore
    }

    private func sendMenuBarNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Tom's Fans is still running"
        content.body = "Fan control is active in the menu bar. Click the menu bar icon to reopen the window or quit."
        let request = UNNotificationRequest(identifier: "window-closed", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Re-apply the persisted control mode on launch or wake.
    private func reapplySavedMode() {
        reapplyMode(settings: settings, fanControl: fanControl, curveEngine: curveEngine)
    }
}

// MARK: - Shared Mode Reapplication

private func reapplyMode(settings: AppSettings, fanControl: XPCFanControlService,
                         curveEngine: FanCurveEngine?) {
    switch settings.controlMode {
    case .automatic:
        break
    case .preset:
        if let presetId = settings.activePresetId,
           let preset = settings.presets.first(where: { $0.id == presetId }) {
            for (fanIndex, rpm) in preset.fanSpeeds {
                if preset.isForceMode {
                    fanControl.setFanMode(fanIndex: fanIndex, mode: 1)
                }
                fanControl.setFanMinSpeed(fanIndex: fanIndex, rpm: rpm)
            }
        }
    case .manual:
        settings.controlMode = .automatic
    case .fanCurve:
        curveEngine?.reset()
    }
}

/// Minimal AppDelegate for lifecycle control.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var isTerminating = false

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.isTerminating = true
    }
}
