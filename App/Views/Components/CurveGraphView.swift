import SwiftUI

/// Fan curve graph with draggable control points and smart snapping.
struct CurveGraphView: View {
    @Binding var controlPoints: [CurvePoint]
    let currentTemp: Double?

    // Local drag state — only committed to binding on drag end
    @State private var dragPoints: [CurvePoint]?
    @State private var dragIndex: Int?

    private let snapUnit: Double = 5
    private let tempMin: Double = 0
    private let tempMax: Double = 100
    private let pctMin: Double = 0
    private let pctMax: Double = 100
    private let hitRadius: CGFloat = 14
    private let pointRadius: CGFloat = 7
    private let inset = EdgeInsets(top: 20, leading: 40, bottom: 24, trailing: 16)

    private var activePoints: [CurvePoint] {
        dragPoints ?? controlPoints
    }

    var body: some View {
        GeometryReader { geo in
            let plotW = geo.size.width - inset.leading - inset.trailing
            let plotH = geo.size.height - inset.top - inset.bottom

            Canvas { ctx, size in
                let plot = CGRect(x: inset.leading, y: inset.top, width: plotW, height: plotH)
                let sorted = activePoints.sorted { $0.temperature < $1.temperature }
                drawGrid(ctx: ctx, plot: plot)
                drawCurve(ctx: ctx, plot: plot, sorted: sorted)
                drawCurrentTemp(ctx: ctx, plot: plot)
                drawPoints(ctx: ctx, plot: plot, sorted: sorted)
            }
            .drawingGroup()
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleDrag(at: value.location, started: value.startLocation,
                                   plotW: plotW, plotH: plotH)
                    }
                    .onEnded { _ in
                        commitDrag()
                    }
            )
        }
    }

    // MARK: - Coordinate Mapping

    private func toScreen(temp: Double, pct: Double, plot: CGRect) -> CGPoint {
        let x = plot.minX + (temp - tempMin) / (tempMax - tempMin) * plot.width
        let y = plot.maxY - (pct - pctMin) / (pctMax - pctMin) * plot.height
        return CGPoint(x: x, y: y)
    }

    private func toData(point: CGPoint, plotW: CGFloat, plotH: CGFloat) -> (temp: Double, pct: Double) {
        let x = (point.x - inset.leading) / plotW
        let y = 1.0 - (point.y - inset.top) / plotH
        let temp = tempMin + x * (tempMax - tempMin)
        let pct = pctMin + y * (pctMax - pctMin)
        return (temp, pct)
    }

    private func snap(_ value: Double) -> Double {
        (value / snapUnit).rounded() * snapUnit
    }

    // MARK: - Drawing

    private func drawGrid(ctx: GraphicsContext, plot: CGRect) {
        // Vertical grid lines (temperature) every 10°C
        for t in stride(from: tempMin, through: tempMax, by: 10) {
            let x = plot.minX + (t - tempMin) / (tempMax - tempMin) * plot.width
            var path = Path()
            path.move(to: CGPoint(x: x, y: plot.minY))
            path.addLine(to: CGPoint(x: x, y: plot.maxY))
            ctx.stroke(path, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)

            // Label
            let label = Text("\(Int(t))°").font(.system(size: 9)).foregroundColor(.secondary)
            ctx.draw(ctx.resolve(label), at: CGPoint(x: x, y: plot.maxY + 12), anchor: .center)
        }

        // Horizontal grid lines (%) every 25%
        for p in stride(from: pctMin, through: pctMax, by: 25) {
            let y = plot.maxY - (p - pctMin) / (pctMax - pctMin) * plot.height
            var path = Path()
            path.move(to: CGPoint(x: plot.minX, y: y))
            path.addLine(to: CGPoint(x: plot.maxX, y: y))
            ctx.stroke(path, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)

            // Label
            let label = Text("\(Int(p))%").font(.system(size: 9)).foregroundColor(.secondary)
            ctx.draw(ctx.resolve(label), at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing)
        }

        // Plot border
        ctx.stroke(Path(plot), with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
    }

    private func drawCurve(ctx: GraphicsContext, plot: CGRect, sorted: [CurvePoint]) {
        guard sorted.count >= 2 else { return }

        // Filled area under curve
        var fillPath = Path()
        let first = toScreen(temp: sorted[0].temperature, pct: Double(sorted[0].percent), plot: plot)
        fillPath.move(to: CGPoint(x: first.x, y: plot.maxY))
        fillPath.addLine(to: first)
        for pt in sorted.dropFirst() {
            let s = toScreen(temp: pt.temperature, pct: Double(pt.percent), plot: plot)
            fillPath.addLine(to: s)
        }
        let last = toScreen(temp: sorted.last!.temperature, pct: Double(sorted.last!.percent), plot: plot)
        fillPath.addLine(to: CGPoint(x: last.x, y: plot.maxY))
        fillPath.closeSubpath()
        ctx.fill(fillPath, with: .color(.blue.opacity(0.08)))

        // Line
        var linePath = Path()
        linePath.move(to: first)
        for pt in sorted.dropFirst() {
            let s = toScreen(temp: pt.temperature, pct: Double(pt.percent), plot: plot)
            linePath.addLine(to: s)
        }
        ctx.stroke(linePath, with: .color(.blue), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    private func drawCurrentTemp(ctx: GraphicsContext, plot: CGRect) {
        guard let temp = currentTemp, temp >= tempMin, temp <= tempMax else { return }
        let x = plot.minX + (temp - tempMin) / (tempMax - tempMin) * plot.width

        var path = Path()
        path.move(to: CGPoint(x: x, y: plot.minY))
        path.addLine(to: CGPoint(x: x, y: plot.maxY))
        ctx.stroke(path, with: .color(.red.opacity(0.5)),
                   style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))

        let label = Text(String(format: "%.0f°C", temp))
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.red)
        ctx.draw(ctx.resolve(label), at: CGPoint(x: x + 4, y: plot.minY - 4), anchor: .bottomLeading)
    }

    private func drawPoints(ctx: GraphicsContext, plot: CGRect, sorted: [CurvePoint]) {
        for (i, pt) in sorted.enumerated() {
            let s = toScreen(temp: pt.temperature, pct: Double(pt.percent), plot: plot)
            let isDragging = dragIndex == i

            // Outer ring
            let outerSize = isDragging ? pointRadius * 2.8 : pointRadius * 2
            let outerRect = CGRect(x: s.x - outerSize / 2, y: s.y - outerSize / 2,
                                   width: outerSize, height: outerSize)
            ctx.fill(Path(ellipseIn: outerRect), with: .color(.blue.opacity(isDragging ? 0.25 : 0.15)))

            // Inner dot
            let innerSize = isDragging ? pointRadius * 1.8 : pointRadius * 1.4
            let innerRect = CGRect(x: s.x - innerSize / 2, y: s.y - innerSize / 2,
                                   width: innerSize, height: innerSize)
            ctx.fill(Path(ellipseIn: innerRect), with: .color(.blue))

            // Annotation
            let annotation = Text("\(Int(pt.temperature))° → \(pt.percent)%")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
            let above = i % 2 == 0 || isDragging
            let labelY = above ? s.y - pointRadius - 6 : s.y + pointRadius + 10
            ctx.draw(ctx.resolve(annotation), at: CGPoint(x: s.x, y: labelY), anchor: .center)
        }
    }

    // MARK: - Drag Handling

    private func handleDrag(at location: CGPoint, started: CGPoint, plotW: CGFloat, plotH: CGFloat) {
        if dragIndex == nil {
            // Find nearest point to start location
            let sorted = controlPoints.sorted { $0.temperature < $1.temperature }
            var bestDist: CGFloat = .infinity
            var bestIdx: Int?
            let plotRect = CGRect(x: inset.leading, y: inset.top, width: plotW, height: plotH)

            for (i, pt) in sorted.enumerated() {
                let s = toScreen(temp: pt.temperature, pct: Double(pt.percent), plot: plotRect)
                let dist = hypot(started.x - s.x, started.y - s.y)
                if dist < hitRadius * 2 && dist < bestDist {
                    bestDist = dist
                    bestIdx = i
                }
            }
            guard let idx = bestIdx else { return }
            dragIndex = idx
            dragPoints = sorted
        }

        guard var points = dragPoints, let idx = dragIndex,
              points.indices.contains(idx) else { return }

        let (rawTemp, rawPct) = toData(point: location, plotW: plotW, plotH: plotH)
        let snappedTemp = snap(rawTemp.clamped(to: tempMin...tempMax))
        let snappedPct = Int(snap(rawPct.clamped(to: pctMin...pctMax)))

        points[idx] = CurvePoint(
            id: points[idx].id,
            temperature: snappedTemp,
            percent: snappedPct
        )
        dragPoints = points
    }

    private func commitDrag() {
        if let points = dragPoints {
            controlPoints = points.sorted { $0.temperature < $1.temperature }
        }
        dragPoints = nil
        dragIndex = nil
    }
}

// MARK: - Helpers

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
