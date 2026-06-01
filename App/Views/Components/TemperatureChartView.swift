import SwiftUI

private let chartPalette: [Color] = [.blue, .orange, .green, .red, .purple, .cyan, .pink, .yellow]
private let chartTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "m:ss"
    return f
}()

struct TemperatureChartView: View {
    let sensorKeys: [String]
    let history: [String: [TemperatureReading]]
    let sensorNames: [String: String]
    let range: TemperatureHistoryRange

    private let inset = EdgeInsets(top: 12, leading: 40, bottom: 40, trailing: 12)

    var body: some View {
        GeometryReader { geo in
            let plotW = max(geo.size.width - inset.leading - inset.trailing, 1)
            let plotH = max(geo.size.height - inset.top - inset.bottom, 1)
            let plot = CGRect(x: inset.leading, y: inset.top, width: plotW, height: plotH)
            let window = chartWindow
            let visibleHistory = filteredHistory(in: window)
            let allReadings = sensorKeys.compactMap { visibleHistory[$0] }.flatMap { $0 }
            let stats = ChartStats(
                readings: allReadings,
                minTime: window.lowerBound,
                maxTime: window.upperBound
            )

            ZStack {
                Canvas { ctx, _ in
                    drawHorizontalGrid(ctx: ctx, plot: plot, stats: stats)
                    drawXAxis(ctx: ctx, plot: plot, stats: stats)
                    drawLines(ctx: ctx, plot: plot, stats: stats)
                }
                .drawingGroup()

                ChartHoverOverlay(
                    plot: plot,
                    stats: stats,
                    sensorKeys: sensorKeys,
                    history: history
                )
            }

            // Legend below chart
            legendView
                .position(x: geo.size.width / 2, y: geo.size.height - 8)
        }
    }

    // MARK: - Data Stats

    fileprivate struct ChartStats {
        let minTemp: Double
        let maxTemp: Double
        let minTime: Date
        let maxTime: Date
        let yStep: Double
        let yFloor: Double
        let yCeil: Double

        init(readings: [TemperatureReading], minTime: Date, maxTime: Date) {
            self.minTime = minTime
            self.maxTime = maxTime

            guard !readings.isEmpty else {
                minTemp = 0; maxTemp = 100
                yStep = 10; yFloor = 0; yCeil = 100
                return
            }
            let temps = readings.map(\.value)
            minTemp = temps.min()!
            maxTemp = temps.max()!

            let rawRange = maxTemp - minTemp
            yStep = Self.niceStep(rawRange > 0 ? rawRange / 4 : 5)
            yFloor = (minTemp / yStep).rounded(.down) * yStep
            yCeil = (maxTemp / yStep).rounded(.up) * yStep
        }

        static func niceStep(_ raw: Double) -> Double {
            let pow10 = Foundation.pow(10, floor(log10(max(raw, 0.001))))
            let frac = raw / pow10
            if frac <= 1 { return pow10 }
            if frac <= 2 { return 2 * pow10 }
            if frac <= 5 { return 5 * pow10 }
            return 10 * pow10
        }

        func yNormalized(_ value: Double) -> Double {
            let range = yCeil - yFloor
            guard range > 0 else { return 0.5 }
            return (value - yFloor) / range
        }

        func xNormalized(_ date: Date) -> Double {
            let range = maxTime.timeIntervalSince(minTime)
            guard range > 0 else { return 0.5 }
            return date.timeIntervalSince(minTime) / range
        }

        func dateFromNormalized(_ norm: Double) -> Date {
            minTime.addingTimeInterval(norm * maxTime.timeIntervalSince(minTime))
        }
    }

    private var chartWindow: ClosedRange<Date> {
        let allReadings = sensorKeys.compactMap { history[$0] }.flatMap { $0 }
        let windowEnd = allReadings.map(\.date).max() ?? Date()
        let windowStart = windowEnd.addingTimeInterval(-range.duration)
        return windowStart...windowEnd
    }

    private func filteredHistory(in window: ClosedRange<Date>) -> [String: [TemperatureReading]] {
        Dictionary(uniqueKeysWithValues: sensorKeys.compactMap { key in
            guard let readings = history[key] else { return nil }
            let visibleReadings = readings.filter { window.contains($0.date) }
            return (key, visibleReadings)
        })
    }

    // MARK: - Grid & Axes

    private func drawHorizontalGrid(ctx: GraphicsContext, plot: CGRect, stats: ChartStats) {
        var y = stats.yFloor
        while y <= stats.yCeil + stats.yStep * 0.01 {
            let norm = stats.yNormalized(y)
            let py = plot.maxY - norm * plot.height

            var gridLine = Path()
            gridLine.move(to: CGPoint(x: plot.minX, y: py))
            gridLine.addLine(to: CGPoint(x: plot.maxX, y: py))
            ctx.stroke(gridLine, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)

            let label = Text("\(Int(y))\u{00B0}").font(.system(size: 9)).foregroundColor(.secondary)
            ctx.draw(ctx.resolve(label), at: CGPoint(x: plot.minX - 4, y: py), anchor: .trailing)
            y += stats.yStep
        }
    }

    private func drawXAxis(ctx: GraphicsContext, plot: CGRect, stats: ChartStats) {
        let range = stats.maxTime.timeIntervalSince(stats.minTime)
        guard range > 0 else { return }

        let tickStride = self.range.axisTickInterval
        let initialTick = floor(stats.minTime.timeIntervalSinceReferenceDate / tickStride) * tickStride
        var tick = Date(timeIntervalSinceReferenceDate: initialTick)
        if tick < stats.minTime { tick = tick.addingTimeInterval(tickStride) }

        while tick <= stats.maxTime {
            let norm = stats.xNormalized(tick)
            let px = plot.minX + norm * plot.width

            var gridLine = Path()
            gridLine.move(to: CGPoint(x: px, y: plot.minY))
            gridLine.addLine(to: CGPoint(x: px, y: plot.maxY))
            ctx.stroke(gridLine, with: .color(.secondary.opacity(0.08)), lineWidth: 0.5)

            let label = Text(chartTimeFormatter.string(from: tick)).font(.system(size: 9)).foregroundColor(.secondary)
            ctx.draw(ctx.resolve(label), at: CGPoint(x: px, y: plot.maxY + 10), anchor: .center)

            tick = tick.addingTimeInterval(tickStride)
        }
    }

    // MARK: - Lines

    private func drawLines(ctx: GraphicsContext, plot: CGRect, stats: ChartStats) {
        for (i, key) in sensorKeys.enumerated() {
            guard let readings = history[key], readings.count >= 2 else { continue }
            let color = chartPalette[i % chartPalette.count]

            var path = Path()
            for (j, r) in readings.enumerated() {
                let px = plot.minX + stats.xNormalized(r.date) * plot.width
                let py = plot.maxY - stats.yNormalized(r.value) * plot.height
                let pt = CGPoint(x: px, y: py)
                if j == 0 { path.move(to: pt) }
                else { path.addLine(to: pt) }
            }
            ctx.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: - Legend

    private var legendView: some View {
        HStack(spacing: 12) {
            ForEach(Array(sensorKeys.enumerated()), id: \.element) { i, key in
                HStack(spacing: 4) {
                    Circle()
                        .fill(chartPalette[i % chartPalette.count])
                        .frame(width: 8, height: 8)
                    Text(sensorNames[key] ?? key)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Owns the hover state so that hover updates only invalidate this overlay,
/// not the parent chart's expensive stats/line computation.
private struct ChartHoverOverlay: View {
    let plot: CGRect
    let stats: TemperatureChartView.ChartStats
    let sensorKeys: [String]
    let history: [String: [TemperatureReading]]

    @State private var hoverLocation: CGPoint?

    var body: some View {
        Canvas { ctx, _ in
            if let loc = hoverLocation {
                drawCrosshair(ctx: ctx, hoverX: loc.x)
            }
        }
        .drawingGroup()
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                // Skip sub-pixel updates — during a scroll, onContinuousHover
                // fires per frame even when the cursor itself hasn't moved.
                if let prev = hoverLocation,
                   abs(prev.x - location.x) < 2,
                   abs(prev.y - location.y) < 2 {
                    return
                }
                hoverLocation = location
            case .ended:
                hoverLocation = nil
            }
        }
    }

    private func drawCrosshair(ctx: GraphicsContext, hoverX: CGFloat) {
        guard hoverX >= plot.minX, hoverX <= plot.maxX else { return }
        let normX = (hoverX - plot.minX) / plot.width
        let hoverDate = stats.dateFromNormalized(normX)

        var line = Path()
        line.move(to: CGPoint(x: hoverX, y: plot.minY))
        line.addLine(to: CGPoint(x: hoverX, y: plot.maxY))
        ctx.stroke(line, with: .color(.secondary.opacity(0.4)),
                   style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))

        let timeText = Text(chartTimeFormatter.string(from: hoverDate))
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.primary)
        ctx.draw(ctx.resolve(timeText),
                 at: CGPoint(x: hoverX, y: plot.maxY + 10), anchor: .center)

        let labelOnLeft = hoverX > plot.midX
        for (i, key) in sensorKeys.enumerated() {
            guard let readings = history[key],
                  let value = interpolatedValue(in: readings, at: hoverDate) else { continue }
            let color = chartPalette[i % chartPalette.count]
            let py = plot.maxY - stats.yNormalized(value) * plot.height

            let dot = Path(ellipseIn: CGRect(x: hoverX - 3.5, y: py - 3.5, width: 7, height: 7))
            ctx.fill(dot, with: .color(color))
            ctx.stroke(dot, with: .color(.white.opacity(0.8)), lineWidth: 1.5)

            let label = Text(String(format: "%.1f\u{00B0}", value))
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(color)
            let lx = labelOnLeft ? hoverX - 8 : hoverX + 8
            ctx.draw(ctx.resolve(label),
                     at: CGPoint(x: lx, y: py),
                     anchor: labelOnLeft ? .trailing : .leading)
        }
    }

    private func interpolatedValue(in readings: [TemperatureReading], at date: Date) -> Double? {
        guard readings.count >= 2 else { return readings.first?.value }
        if date <= readings.first!.date { return readings.first!.value }
        if date >= readings.last!.date { return readings.last!.value }
        var lo = 0, hi = readings.count - 1
        while lo < hi - 1 {
            let mid = (lo + hi) / 2
            if readings[mid].date <= date { lo = mid }
            else { hi = mid }
        }
        let a = readings[lo], b = readings[hi]
        let span = b.date.timeIntervalSince(a.date)
        guard span > 0 else { return a.value }
        let t = date.timeIntervalSince(a.date) / span
        return a.value + t * (b.value - a.value)
    }
}
