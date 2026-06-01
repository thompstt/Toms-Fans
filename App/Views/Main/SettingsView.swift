import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var helperInstall: HelperInstallService
    @EnvironmentObject var errorLog: ErrorLog

    var body: some View {
        Form {
            Section("General") {
                Picker("Temperature Unit", selection: $settings.temperatureUnit) {
                    Text("Celsius").tag(AppSettings.TemperatureUnit.celsius)
                    Text("Fahrenheit").tag(AppSettings.TemperatureUnit.fahrenheit)
                }

                HStack {
                    Text("Poll Interval:")
                    Slider(value: $settings.pollInterval, in: 1...10, step: 0.5)
                    Text("\(String(format: "%.1f", settings.pollInterval))s")
                        .monospacedDigit()
                        .frame(width: 40)
                }

                Toggle("Show Temperature in Menu Bar", isOn: $settings.showTemperatureInMenuBar)
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
            }

            Section("Helper Tool") {
                HStack {
                    Text("Status:")
                    Text(helperInstall.statusDescription)
                        .foregroundStyle(helperInstall.isHelperRunning ? .green : .orange)
                }

                if !helperInstall.isHelperRunning {
                    Button("Install Helper") {
                        helperInstall.register()
                    }
                    Text("The helper tool runs with elevated privileges to control fan speeds. You'll be asked to approve it in System Settings > Login Items & Extensions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if helperInstall.needsApproval {
                        Button("Open Login Items Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                } else {
                    Button("Uninstall Helper") {
                        helperInstall.unregister()
                    }
                }

                if let error = helperInstall.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Temperature Alerts") {
                Text("Get notified when temperatures exceed these thresholds:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(Array(settings.alertThresholds.sorted(by: { $0.key < $1.key })), id: \.key) { key, threshold in
                    HStack {
                        Text(KnownSensors.name(for: key) ?? key)
                        Spacer()
                        TextField("°C", value: Binding(
                            get: { threshold },
                            set: { settings.alertThresholds[key] = $0 }
                        ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        Text("°C")

                        Button(action: { settings.alertThresholds.removeValue(forKey: key) }) {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section {
                Toggle("Revert to automatic if CPU gets too hot", isOn: $settings.thermalLockoutEnabled)

                HStack {
                    Stepper(value: $settings.thermalCeilingC,
                            in: ThermalCeiling.minC...ThermalCeiling.maxC,
                            step: 1) {
                        Text("Ceiling: \(Int(settings.thermalCeilingC))°C")
                            .monospacedDigit()
                    }
                    .disabled(!settings.thermalLockoutEnabled)
                }
            } header: {
                Text("Thermal Safety")
            } footer: {
                if settings.thermalLockoutEnabled {
                    Text("While a fan curve or manual speed is active, the helper reverts all fans to automatic if the CPU package reaches this temperature, then resumes once it cools. 90°C is normal under load on this hardware; the default 97°C leaves margin below the CPU's ~100°C throttle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Forced and curve fan modes will have NO software thermal protection — only the CPU's built-in ~100°C throttle, which does not protect the GPU, VRMs, or battery. Crash protection (revert to automatic when the app exits) still applies.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Error Log") {
                if errorLog.entries.isEmpty {
                    Text("No errors recorded this session.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    HStack {
                        Text("\(errorLog.entries.count) entries")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") {
                            errorLog.clearLog()
                        }
                        .font(.caption)
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(errorLog.entries.reversed()) { entry in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(entry.date, format: .dateTime.hour().minute().second())
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 70, alignment: .leading)

                                    Text(entry.source.rawValue)
                                        .font(.caption2.bold())
                                        .foregroundStyle(entry.severity == .critical ? .red : .orange)
                                        .frame(width: 30, alignment: .leading)

                                    Text(entry.message)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                        .padding(8)
                    }
                    .frame(minHeight: 120, maxHeight: 200)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            Section("About") {
                Text("Tom's Fans v1.0")
                Text("Temperature monitoring and fan control for MacBook Pro")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Monitor processes", isOn: $settings.processMonitoringEnabled)
                Toggle("Allow remediation (Quit / Force Quit / Throttle)", isOn: $settings.remediationEnabled)
                    .disabled(!settings.processMonitoringEnabled)
            } header: {
                Text("Task Manager")
            } footer: {
                Text("Process monitoring identifies likely heat sources. Remediation lets you act on them with one click. Throttled processes are released within 10 seconds or sooner if temperatures drop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 400)
    }
}
