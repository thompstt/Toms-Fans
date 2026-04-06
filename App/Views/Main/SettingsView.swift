import SwiftUI

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
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 400)
    }
}
