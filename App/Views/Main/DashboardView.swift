import SwiftUI

struct SensorGroup: Identifiable {
    let category: SensorCategory
    let sensors: [TemperatureSensor]
    var id: String { category.rawValue }

    var representativeTemp: Double {
        let packageKeys: [String]
        switch category {
        case .cpu:    packageKeys = ["TCXC", "TC0D", "TC0P"]
        case .gpu:    packageKeys = ["TG0D", "TG0P"]
        case .memory: packageKeys = ["TM0P"]
        default:      packageKeys = []
        }
        for key in packageKeys {
            if let s = sensors.first(where: { $0.key == key }) {
                return s.value
            }
        }
        guard !sensors.isEmpty else { return 0 }
        return sensors.map(\.value).reduce(0, +) / Double(sensors.count)
    }

    var representativeLabel: String {
        let packageKeys: [String]
        switch category {
        case .cpu:    packageKeys = ["TCXC", "TC0D", "TC0P"]
        case .gpu:    packageKeys = ["TG0D", "TG0P"]
        case .memory: packageKeys = ["TM0P"]
        default:      packageKeys = []
        }
        for key in packageKeys {
            if let s = sensors.first(where: { $0.key == key }) {
                return s.name
            }
        }
        return "Average"
    }
}

// MARK: - Extracted Child Views

struct SummaryStripView: View, Equatable {
    let cpuTemp: Double
    let gpuTemp: Double
    let fans: [Fan]

    var body: some View {
        HStack(spacing: 8) {
            SummaryCard(
                icon: "cpu",
                label: "CPU",
                value: String(format: "%.0f°", cpuTemp),
                color: tempColor(cpuTemp)
            )
            SummaryCard(
                icon: "display",
                label: "GPU",
                value: String(format: "%.0f°", gpuTemp),
                color: tempColor(gpuTemp)
            )
            ForEach(fans) { fan in
                SummaryCard(
                    icon: "fan.fill",
                    label: fan.name,
                    value: "\(Int(fan.actualRPM)) RPM",
                    color: fanColor(fan)
                )
            }
        }
    }
}

struct ModeSelectionView: View, Equatable {
    let controlMode: FanControlMode
    let automaticSubtitle: String
    let manualSubtitle: String
    let presetSubtitle: String
    let curveSubtitle: String
    let onSelectMode: (FanControlMode) -> Void

    static func == (lhs: ModeSelectionView, rhs: ModeSelectionView) -> Bool {
        lhs.controlMode == rhs.controlMode
            && lhs.automaticSubtitle == rhs.automaticSubtitle
            && lhs.manualSubtitle == rhs.manualSubtitle
            && lhs.presetSubtitle == rhs.presetSubtitle
            && lhs.curveSubtitle == rhs.curveSubtitle
    }

    var body: some View {
        HStack(spacing: 8) {
            ModeCard(
                icon: "gearshape",
                title: "Automatic",
                subtitle: automaticSubtitle,
                isActive: controlMode == .automatic
            ) { onSelectMode(.automatic) }

            ModeCard(
                icon: "slider.horizontal.3",
                title: "Manual",
                subtitle: manualSubtitle,
                isActive: controlMode == .manual
            ) { onSelectMode(.manual) }

            ModeCard(
                icon: "square.grid.2x2",
                title: "Preset",
                subtitle: presetSubtitle,
                isActive: controlMode == .preset
            ) { onSelectMode(.preset) }

            ModeCard(
                icon: "chart.line.uptrend.xyaxis",
                title: "Fan Curve",
                subtitle: curveSubtitle,
                isActive: controlMode == .fanCurve
            ) { onSelectMode(.fanCurve) }
        }
    }
}

struct SensorSidebarView: View {
    let temperatures: [TemperatureSensor]
    @Binding var chartSensorKeys: Set<String>
    @Binding var expandedCategories: Set<SensorCategory>

    var body: some View {
        let grouped = Dictionary(grouping: temperatures, by: \.category)
        let groups = SensorCategory.allCases.compactMap { cat -> SensorGroup? in
            guard let sensors = grouped[cat], !sensors.isEmpty else { return nil }
            return SensorGroup(category: cat, sensors: sensors)
        }

        List {
            ForEach(groups) { group in
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedCategories.contains(group.category) },
                    set: { val in
                        if val { expandedCategories.insert(group.category) }
                        else { expandedCategories.remove(group.category) }
                    }
                )) {
                    ForEach(group.sensors) { sensor in
                        CompactSensorRow(
                            sensor: sensor,
                            isCharted: chartSensorKeys.contains(sensor.key)
                        ) {
                            if chartSensorKeys.contains(sensor.key) {
                                chartSensorKeys.remove(sensor.key)
                            } else {
                                chartSensorKeys.insert(sensor.key)
                            }
                        }
                    }
                } label: {
                    CompactCategoryHeader(group: group)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 160, idealWidth: 190, maxWidth: 240)
    }
}

struct TemperatureChartSection: View {
    let chartSensorKeys: Set<String>
    let chartHistory: [String: [TemperatureReading]]
    let sensorNames: [String: String]
    @Binding var chartRange: TemperatureHistoryRange

    var body: some View {
        GroupBox("Temperature History") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer()
                    Picker("Time Range", selection: $chartRange) {
                        ForEach(TemperatureHistoryRange.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 150)
                }

                if chartSensorKeys.isEmpty {
                    Text("Click a sensor to add it to the chart")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    TemperatureChartView(
                        sensorKeys: chartSensorKeys.sorted {
                            (sensorNames[$0] ?? $0) < (sensorNames[$1] ?? $1)
                        },
                        history: chartHistory,
                        sensorNames: sensorNames,
                        range: chartRange
                    )
                    .frame(minHeight: 180)
                }
            }
        }
    }
}

struct ManualFanControlSection: View {
    let fans: [Fan]
    @Binding var manualSpeeds: [Int: Double]
    @Binding var manualRPMText: [Int: String]
    let onApply: (Fan) -> Void

    var body: some View {
        GroupBox("Manual Fan Control") {
            HStack(alignment: .top, spacing: 32) {
                ForEach(fans) { fan in
                    VStack(spacing: 8) {
                        FanGaugeView(fan: fan)
                            .frame(width: 120, height: 120)

                        Text(fan.name).font(.headline)

                        if fan.maxRPM > fan.minRPM {
                            manualControlView(for: fan)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func manualControlView(for fan: Fan) -> some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { manualSpeeds[fan.index] ?? fan.actualRPM },
                    set: { newValue in
                        manualSpeeds[fan.index] = newValue
                        manualRPMText[fan.index] = "\(Int(newValue))"
                    }
                ),
                in: fan.minRPM...fan.maxRPM,
                step: 100
            ) {
                Text("Speed")
            }

            HStack(spacing: 8) {
                TextField("RPM", text: Binding(
                    get: { manualRPMText[fan.index] ?? "\(Int(manualSpeeds[fan.index] ?? fan.actualRPM))" },
                    set: { text in
                        manualRPMText[fan.index] = text
                        if let val = Double(text),
                           val >= fan.minRPM, val <= fan.maxRPM {
                            manualSpeeds[fan.index] = val
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .onSubmit {
                    onApply(fan)
                }

                Text("RPM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 200)

        Button("Apply") {
            onApply(fan)
        }
        .buttonStyle(.borderedProminent)
    }
}

struct PresetSection: View, Equatable {
    let presets: [FanPreset]
    let activePresetId: UUID?
    let onSelect: (FanPreset) -> Void

    static func == (lhs: PresetSection, rhs: PresetSection) -> Bool {
        lhs.presets == rhs.presets && lhs.activePresetId == rhs.activePresetId
    }

    var body: some View {
        GroupBox("Presets") {
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                ForEach(presets) { preset in
                    PresetButton(
                        title: preset.name,
                        icon: presetIcon(preset),
                        isActive: activePresetId == preset.id
                    ) {
                        onSelect(preset)
                    }
                }
            }
            .padding(4)
        }
    }

    private func presetIcon(_ preset: FanPreset) -> String {
        switch preset.name.lowercased() {
        case "silent": return "speaker.slash.fill"
        case "balanced": return "equal.circle.fill"
        case "performance": return "bolt.fill"
        case "full blast": return "wind"
        default: return "fan.fill"
        }
    }
}

// MARK: - Shared Color Helpers

private func tempColor(_ temp: Double) -> Color {
    if temp > 90 { return .red }
    if temp > 75 { return .orange }
    if temp > 60 { return .yellow }
    return .green
}

private func fanColor(_ fan: Fan) -> Color {
    let pct = fan.speedPercentage
    if pct > 80 { return .red }
    if pct > 50 { return .orange }
    if pct > 25 { return .yellow }
    return .green
}

// MARK: - Dashboard (Thin Orchestrator)

struct DashboardView: View {
    @EnvironmentObject var monitor: SMCMonitorService
    @EnvironmentObject var fanControl: XPCFanControlService
    @EnvironmentObject var curveEngine: FanCurveEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var errorLog: ErrorLog
    @State private var chartSensorKeys: Set<String> = ["TCXC", "TG0P"]
    @State private var expandedCategories: Set<SensorCategory> = []
    @State private var manualSpeeds: [Int: Double] = [:]
    @State private var manualRPMText: [Int: String] = [:]
    @State private var showSidebar = true

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                SensorSidebarView(
                    temperatures: monitor.temperatures,
                    chartSensorKeys: $chartSensorKeys,
                    expandedCategories: $expandedCategories
                )
                Divider()
            }
            mainPanel
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSidebar.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(showSidebar ? "Hide Sensors" : "Show Sensors")
            }
        }
    }

    private var mainPanel: some View {
        ScrollView {
            LazyVStack(alignment: .center, spacing: 12) {
                if !errorLog.activeConditions.isEmpty {
                    ErrorBannerView(conditions: errorLog.activeConditions)
                } else if !monitor.isConnected {
                    ErrorBannerView(conditions: [
                        "smc.disconnected": ErrorEntry(
                            date: Date(), source: .smc, severity: .critical,
                            message: "SMC connection failed — temperature monitoring unavailable"
                        )
                    ])
                }

                SummaryStripView(
                    cpuTemp: monitor.cpuPackageTemp,
                    gpuTemp: monitor.gpuTemp,
                    fans: monitor.fans
                )

                ModeSelectionView(
                    controlMode: settings.controlMode,
                    automaticSubtitle: automaticSubtitle,
                    manualSubtitle: manualSubtitle,
                    presetSubtitle: activePresetName,
                    curveSubtitle: activeCurveName,
                    onSelectMode: { mode in
                        settings.controlMode = mode
                        handleModeChange(mode)
                    }
                )

                TemperatureChartSection(
                    chartSensorKeys: chartSensorKeys,
                    chartHistory: monitor.chartHistory,
                    sensorNames: monitor.sensorNames,
                    chartRange: Binding(
                        get: { settings.temperatureHistoryRange },
                        set: { settings.temperatureHistoryRange = $0 }
                    )
                )

                if settings.controlMode == .manual {
                    ManualFanControlSection(
                        fans: monitor.fans,
                        manualSpeeds: $manualSpeeds,
                        manualRPMText: $manualRPMText,
                        onApply: applyManualSpeed
                    )
                }

                if settings.controlMode == .preset {
                    PresetSection(
                        presets: settings.presets,
                        activePresetId: settings.activePresetId,
                        onSelect: applyPreset
                    )
                }

                // Fan Curve editor stays inline (needs settings binding + monitor.temperatures)
                if settings.controlMode == .fanCurve, !settings.fanCurves.isEmpty {
                    fanCurveSection
                }

            }
            .padding(12)
        }
        .frame(minWidth: 450)
    }

    // MARK: - Inline Fan Curve Editor

    private var editingCurveIndex: Int {
        if let idx = settings.fanCurves.firstIndex(where: { $0.id == settings.activeCurveId }) {
            return idx
        }
        return 0
    }

    private var fanCurveSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Profile", selection: Binding(
                        get: { settings.activeCurveId ?? settings.fanCurves.first?.id ?? UUID() },
                        set: { settings.activeCurveId = $0 }
                    )) {
                        ForEach(settings.fanCurves) { curve in
                            Text(curve.name).tag(curve.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)

                    Button(action: addCurve) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)

                    Button(action: removeCurve) {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(settings.fanCurves.count <= 1)

                    Spacer()

                    if settings.fanCurves.indices.contains(editingCurveIndex) {
                        TextField("Name", text: $settings.fanCurves[editingCurveIndex].name)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 160)
                    }
                }

                if settings.fanCurves.indices.contains(editingCurveIndex) {
                    let curveBinding = $settings.fanCurves[editingCurveIndex]

                    HStack(spacing: 16) {
                        HStack(spacing: 4) {
                            Text("Sensor:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("Sensor", selection: curveBinding.sensorKey) {
                                ForEach(monitor.sensorNames.filter { $0.key.hasPrefix("TC") || $0.key.hasPrefix("TG") }.sorted(by: { $0.key < $1.key }), id: \.key) { key, name in
                                    Text(name).tag(key)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 180)
                        }

                        HStack(spacing: 4) {
                            Text("Hysteresis:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: curveBinding.hysteresis, in: 0...10, step: 0.5)
                                .frame(width: 100)
                            Text(String(format: "%.1f°C", settings.fanCurves[editingCurveIndex].hysteresis))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .leading)
                        }

                        HStack(spacing: 4) {
                            Text("Fans:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Toggle("L", isOn: Binding(
                                get: { settings.fanCurves[editingCurveIndex].appliesToFans.contains(0) },
                                set: { on in
                                    if on { if !settings.fanCurves[editingCurveIndex].appliesToFans.contains(0) { settings.fanCurves[editingCurveIndex].appliesToFans.append(0) } }
                                    else { settings.fanCurves[editingCurveIndex].appliesToFans.removeAll { $0 == 0 } }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            Toggle("R", isOn: Binding(
                                get: { settings.fanCurves[editingCurveIndex].appliesToFans.contains(1) },
                                set: { on in
                                    if on { if !settings.fanCurves[editingCurveIndex].appliesToFans.contains(1) { settings.fanCurves[editingCurveIndex].appliesToFans.append(1) } }
                                    else { settings.fanCurves[editingCurveIndex].appliesToFans.removeAll { $0 == 1 } }
                                }
                            ))
                            .toggleStyle(.checkbox)
                        }

                        Spacer()
                    }

                    CurveGraphView(
                        controlPoints: curveBinding.controlPoints,
                        currentTemp: monitor.temperatures.first(where: { $0.key == settings.fanCurves[editingCurveIndex].sensorKey }).map { $0.value.rounded() }
                    )
                    .frame(minHeight: 200)

                    curvePointsEditor(curveBinding: curveBinding)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Text("Fan Curve")
        }
    }

    @ViewBuilder
    private func curvePointsEditor(curveBinding: Binding<FanCurve>) -> some View {
        let curve = curveBinding.wrappedValue
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Temp (°C)")
                    .frame(width: 90, alignment: .leading)
                Text("Speed (%)")
                    .frame(width: 80, alignment: .leading)
                Text("≈ RPM")
                    .frame(width: 70, alignment: .leading)
                Spacer()
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.bottom, 4)

            Divider()

            ForEach(Array(curve.controlPoints.enumerated()), id: \.element.id) { index, point in
                HStack(spacing: 6) {
                    TextField("°C", value: Binding(
                        get: { curveBinding.wrappedValue.controlPoints[index].temperature },
                        set: { curveBinding.wrappedValue.controlPoints[index].temperature = $0 }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)

                    TextField("%", value: Binding(
                        get: { curveBinding.wrappedValue.controlPoints[index].percent },
                        set: { curveBinding.wrappedValue.controlPoints[index].percent = min(max($0, 0), 100) }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)

                    Text(approximateRPM(curve: curve, percent: point.percent))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)

                    Button(action: { curveBinding.wrappedValue.controlPoints.remove(at: index) }) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(curve.controlPoints.count <= 2)
                    .opacity(curve.controlPoints.count <= 2 ? 0.3 : 1)

                    Spacer()
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
            }

            Divider()
                .padding(.top, 2)

            Button(action: {
                let lastPct = curveBinding.wrappedValue.controlPoints.last?.percent ?? 50
                let lastTemp = curveBinding.wrappedValue.controlPoints.last?.temperature ?? 50
                curveBinding.wrappedValue.controlPoints.append(
                    CurvePoint(temperature: lastTemp + 10, percent: min(lastPct + 10, 100))
                )
                curveBinding.wrappedValue.controlPoints.sort { $0.temperature < $1.temperature }
            }) {
                Label("Add Point", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
        }
    }

    private func approximateRPM(curve: FanCurve, percent: Int) -> String {
        guard let fan = monitor.fans.first(where: { curve.appliesToFans.contains($0.index) }),
              fan.maxRPM > fan.minRPM else { return "—" }
        let rpm = FanCurve.percentToRPM(percent, minRPM: fan.minRPM, maxRPM: fan.maxRPM)
        return "~\(rpm)"
    }

    private func addCurve() {
        let curve = FanCurve(
            name: "New Curve",
            sensorKey: "TCXC",
            controlPoints: [
                CurvePoint(temperature: 40, percent: 0),
                CurvePoint(temperature: 70, percent: 40),
                CurvePoint(temperature: 90, percent: 100),
            ],
            appliesToFans: [0, 1]
        )
        settings.fanCurves.append(curve)
        settings.activeCurveId = curve.id
    }

    private func removeCurve() {
        guard settings.fanCurves.count > 1 else { return }
        settings.fanCurves.removeAll { $0.id == settings.activeCurveId }
        settings.activeCurveId = settings.fanCurves.first?.id
    }

    // MARK: - Actions

    private func applyManualSpeed(for fan: Fan) {
        let rpm = Int(manualSpeeds[fan.index] ?? fan.actualRPM)
        fanControl.setFanMode(fanIndex: fan.index, mode: 1)
        fanControl.setFanMinSpeed(fanIndex: fan.index, rpm: rpm)
    }

    private func handleModeChange(_ mode: FanControlMode) {
        switch mode {
        case .automatic:
            fanControl.restoreAutomatic()
            settings.activePresetId = nil
        case .manual:
            for fan in monitor.fans {
                manualSpeeds[fan.index] = fan.actualRPM
                manualRPMText[fan.index] = "\(Int(fan.actualRPM))"
            }
        case .preset:
            let preset = settings.presets.first(where: { $0.id == settings.activePresetId })
                ?? settings.presets.first(where: { $0.name == "Balanced" })
                ?? settings.presets.first
            if let preset {
                applyPreset(preset)
            }
        case .fanCurve:
            if settings.fanCurves.first(where: { $0.id == settings.activeCurveId }) == nil {
                settings.activeCurveId = settings.fanCurves.first?.id
            }
            curveEngine.reset()
        }
    }

    private func applyPreset(_ preset: FanPreset) {
        settings.activePresetId = preset.id
        for (fanIndex, rpm) in preset.fanSpeeds {
            if preset.isForceMode {
                fanControl.setFanMode(fanIndex: fanIndex, mode: 1)
            }
            fanControl.setFanMinSpeed(fanIndex: fanIndex, rpm: rpm)
        }
    }

    // MARK: - Computed Subtitles

    private var automaticSubtitle: String {
        if settings.controlMode == .automatic, !monitor.fans.isEmpty {
            let rpms = monitor.fans.map { "\(Int($0.actualRPM))" }.joined(separator: " / ")
            return "\(rpms) RPM"
        }
        return "macOS managed"
    }

    private var manualSubtitle: String {
        if settings.controlMode == .manual, !monitor.fans.isEmpty {
            let rpms = monitor.fans.map { "\(Int($0.actualRPM))" }.joined(separator: " / ")
            return "\(rpms) RPM"
        }
        return "Set custom speeds"
    }

    private var activePresetName: String {
        if let id = settings.activePresetId,
           let preset = settings.presets.first(where: { $0.id == id }) {
            return preset.name
        }
        return "Select a preset"
    }

    private var activeCurveName: String {
        if let curve = settings.fanCurves.first(where: { $0.id == settings.activeCurveId }) {
            return curve.name
        }
        return "No curve selected"
    }
}

// MARK: - Summary Card

struct SummaryCard: View {
    let icon: String
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.body, design: .monospaced).bold())
                    .foregroundStyle(color)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Compact Category Header (for thin sidebar)

struct CompactCategoryHeader: View {
    let group: SensorGroup

    var temperatureColor: Color {
        let t = group.representativeTemp
        if t > 90 { return .red }
        if t > 75 { return .orange }
        if t > 60 { return .yellow }
        return .green
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: group.category.icon)
                .foregroundStyle(temperatureColor)
                .frame(width: 14)

            Text(group.category.rawValue)
                .font(.subheadline.bold())
                .lineLimit(1)

            Spacer()

            Text(String(format: "%.0f°", group.representativeTemp))
                .font(.subheadline.monospacedDigit().bold())
                .foregroundStyle(temperatureColor)
        }
    }
}

// MARK: - Compact Sensor Row (for thin sidebar)

struct CompactSensorRow: View {
    let sensor: TemperatureSensor
    let isCharted: Bool
    let toggleChart: () -> Void

    var temperatureColor: Color {
        if sensor.value > 90 { return .red }
        if sensor.value > 75 { return .orange }
        if sensor.value > 60 { return .yellow }
        return .green
    }

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(temperatureColor)
                .frame(width: 3, height: 20)

            Text(sensor.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Text(sensor.formattedValue)
                .font(.caption.monospacedDigit())
                .foregroundStyle(temperatureColor)

            Button(action: toggleChart) {
                Image(systemName: isCharted
                      ? "chart.line.uptrend.xyaxis.circle.fill"
                      : "chart.line.uptrend.xyaxis.circle")
                    .foregroundStyle(isCharted ? Color.accentColor : Color.secondary.opacity(0.4))
                    .font(.caption2)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Mode Card

struct ModeCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(isActive ? .white : .secondary)
                    .frame(height: 22)

                Text(title)
                    .font(.callout.bold())
                    .foregroundStyle(isActive ? .white : .primary)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(isActive ? .white.opacity(0.7) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preset Button

struct PresetButton: View {
    let title: String
    let icon: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isActive ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}
