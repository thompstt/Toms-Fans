import SwiftUI

struct CulpritCardView: View {
    let culprit: ProcessCulprit
    let displayMode: CPUDisplayMode
    let remediationEnabled: Bool
    let onQuit: (pid_t, String) -> Void
    let onForceQuit: (pid_t, String) -> Void
    let onThrottle: (pid_t, String) -> Void

    @State private var showForceQuitConfirm = false
    @State private var pendingForceQuit: (pid: pid_t, name: String)?

    var body: some View {
        GroupBox {
            content
                .padding(.vertical, 4)
        }
        .confirmationDialog(
            "Force quit \(pendingForceQuit?.name ?? "process")?",
            isPresented: $showForceQuitConfirm,
            titleVisibility: .visible
        ) {
            Button("Force Quit", role: .destructive) {
                if let p = pendingForceQuit { onForceQuit(p.pid, p.name) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Unsaved work may be lost.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch culprit {
        case .candidate(let pid, let name, let sustainedRawPct):
            candidateView(pid: pid, name: name, rawPct: sustainedRawPct)
        case .macOSCooling:
            informationalView(
                icon: "thermometer.snowflake",
                color: .blue,
                title: "macOS is actively cooling",
                detail: "kernel_task is parking cores to lower the chip temperature. No action needed."
            )
        case .noCPUSource:
            informationalView(
                icon: "exclamationmark.triangle",
                color: .orange,
                title: "Heat source not on CPU",
                detail: "Temperatures are high but no CPU process is sustaining heavy load — likely GPU or I/O."
            )
        case .degraded(let reason):
            informationalView(
                icon: "questionmark.circle",
                color: .secondary,
                title: "Process monitoring unavailable",
                detail: "macOS thermal management is in control. (\(reason))"
            )
        }
    }

    private func candidateView(pid: pid_t, name: String, rawPct: Double) -> some View {
        let displayValue = displayMode == .raw1600
            ? rawPct
            : rawPct / Double(ProcessSampler.logicalCoreCount)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "flame.fill")
                .foregroundStyle(.red)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(name) is sustaining \(String(format: "%.0f", displayValue))% CPU")
                    .font(.body.bold())
                Text("Likely heat source. PID \(pid).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if remediationEnabled {
                    HStack(spacing: 8) {
                        Button("Quit") { onQuit(pid, name) }
                            .buttonStyle(.bordered)
                        Button("Force Quit") {
                            pendingForceQuit = (pid, name)
                            showForceQuitConfirm = true
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        Button("Throttle 10s") { onThrottle(pid, name) }
                            .buttonStyle(.bordered)
                    }
                    .padding(.top, 4)
                } else {
                    Text("Enable remediation in Settings to act on this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            Spacer()
        }
    }

    private func informationalView(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
