import SwiftUI

struct ProcessListView: View {
    let samples: [ProcessSample]
    let hostCPUPercent: Double
    @Binding var displayMode: CPUDisplayMode

    var body: some View {
        GroupBox("Processes") {
            VStack(alignment: .leading, spacing: 8) {
                header
                Divider()
                rows
                Divider()
                footer
            }
            .padding(.vertical, 4)
        }
    }

    private var header: some View {
        HStack {
            Picker("Display", selection: $displayMode) {
                Text("0–100%").tag(CPUDisplayMode.normalized100)
                Text("0–\(ProcessSampler.logicalCoreCount * 100)%").tag(CPUDisplayMode.raw1600)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            Spacer()

            Text("System: \(Int(hostCPUPercent))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Process").frame(maxWidth: .infinity, alignment: .leading)
                Text("PID").frame(width: 60, alignment: .trailing)
                Text("CPU%").frame(width: 70, alignment: .trailing)
                Text("Mem").frame(width: 80, alignment: .trailing)
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.bottom, 2)

            ForEach(samples.prefix(20)) { sample in
                HStack {
                    Text(sample.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(sample.pid)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    Text(cpuLabel(sample))
                        .font(.caption.monospacedDigit())
                        .frame(width: 70, alignment: .trailing)
                    Text(memoryLabel(sample.rssBytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
        }
    }

    private var footer: some View {
        Text("Showing top \(min(samples.count, 20)) of \(samples.count)")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func cpuLabel(_ s: ProcessSample) -> String {
        let value = displayMode == .raw1600 ? s.cpuRawPct : s.cpuNormalizedPct
        return String(format: "%.1f", value)
    }

    private func memoryLabel(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }
}
