import Foundation
import UserNotifications

/// Sends macOS notifications when temperature thresholds are exceeded.
final class NotificationService: ObservableObject {
    private var lastAlertTimes: [String: Date] = [:]
    private let cooldownInterval: TimeInterval = 60  // Once per minute per sensor
    private var lastCulpritAlertAt: Date?
    private let culpritCooldown: TimeInterval = 120
    private var degradedNotifiedThisSession = false

    func setup() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func checkThresholds(temperatures: [TemperatureSensor], thresholds: [String: Double]) {
        for sensor in temperatures {
            guard let threshold = thresholds[sensor.key],
                  sensor.value > threshold else { continue }

            // Cooldown check
            if let lastAlert = lastAlertTimes[sensor.key],
               Date().timeIntervalSince(lastAlert) < cooldownInterval { continue }

            sendAlert(sensor: sensor, threshold: threshold)
            lastAlertTimes[sensor.key] = Date()
        }
    }

    private func sendAlert(sensor: TemperatureSensor, threshold: Double) {
        let content = UNMutableNotificationContent()
        content.title = "Temperature Warning"
        content.body = "\(sensor.name) is at \(String(format: "%.0f", sensor.value))°C (threshold: \(Int(threshold))°C)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "temp-\(sensor.key)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func notifyCulprit(name: String, pid: pid_t, rawPct: Double) {
        if let last = lastCulpritAlertAt, Date().timeIntervalSince(last) < culpritCooldown {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Heat source detected"
        content.body = "\(name) is sustaining \(Int(rawPct))% CPU. Open Tom's Fans to act."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "culprit-\(pid)-\(Int(Date().timeIntervalSince1970))",
            content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
        lastCulpritAlertAt = Date()
    }

    func notifyDegraded(reason: String) {
        if degradedNotifiedThisSession { return }
        degradedNotifiedThisSession = true
        let content = UNMutableNotificationContent()
        content.title = "Process monitoring unavailable"
        content.body = "macOS thermal management is in control. (\(reason))"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "degraded-\(Int(Date().timeIntervalSince1970))",
            content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
