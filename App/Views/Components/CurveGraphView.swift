import SwiftUI

private let curveTempMin: Double = 0
private let curveTempMax: Double = 100
private let curvePctMin: Double = 0
private let curvePctMax: Double = 100
private let curvePointRadius: CGFloat = 7
private let curveInset = EdgeInsets(top: 20, leading: 40, bottom: 24, trailing: 16)

private func curveToScreen(temp: Double, pct: Double, plot: CGRect) -> CGPoint {
    let x = plot.minX + (temp - curveTempMin) / (curveTempMax - curveTempMin) * plot.width
    let y = plot.maxY - (pct - curvePctMin) / (curvePctMax - curvePctMin) * plot.height
    return CGPoint(x: x, y: y)
}

/// Fan curve graph with draggable control points and smart snapping.
///
/// Split into three layers so that a polling-rate `currentTemp` update only
/// repaints the cheap indicator line, not the grid or the curve itself.
struct CurveGraphView: View {
    @Binding var controlPoints: [CurvePoint]
    let currentTemp: Double?

    // Local drag state — only committed to binding on drag end
    @State private var dragPoints: [CurvePoint]?
    @State private var dragIndex: Int?

    private let snapUnit: Double = 5
    private let hitRadius: CGFloat = 14

    private var activePoints: [CurvePoint] {
        dragPoints ?? controlPoints
    }

    var body: some View {
        GeometryReader { geo in
            let plotW = geo.size.width - curveInset.leading - curveInset.trailing
            let plotH = geo.size.height - curveInset.top - curveInset.bottom
            let plot = CGRect(x: curveInset.leading, y: curveInset.top,
                              width: plotW, height: plotH)
            let sorted = activePoints.sorted { $0.temperature < $1.temperature }

            ZStack {
                CurveGridLayer(plot: plot)
                CurveAndPointsLayer(plot: plot, sorted: sorted, dragIndex: dragIndex)
                CurveCurrentTempIndicator(plot: plot, currentTemp: currentTemp)
                    .allowsHitTesting(false)
            }
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

    // MARK: - Drag Handling

    private func toData(point: CGPoint, plotW: CGFloat, plotH: CGFloat) -> (temp: Double, pct: Double) {
        let x = (point.x - curveInset.leading) / plotW
        let y = 1.0 - (point.y - curveInset.top) / plotH
        let temp = curveTempMin + x * (curveTempMax - curveTempMin)
        let pct = curvePctMin + y * (curvePctMax - curvePctMin)
        return (temp, pct)
    }

    private func snap(_ value: Double) -> Double {
        (value / snapUnit).rounded() * snapUnit
    }

    private func handleDrag(at location: CGPoint, started: CGPoint, plotW: CGFloat, plotH: CGFloat) {
        if dragIndex == nil {
            let sorted = controlPoints.sorted { $0.temperature < $1.temperature }
            var bestDist: CGFloat = .infinity
            var bestIdx: Int?
            let plotRect = CGRect(x: curveInset.leading, y: curveInset.top, width: plotW, height: plotH)

            for (i, pt) in sorted.enumerated() {
                let s = curveToScreen(temp: pt.temperature, pct: Double(pt.percent), plot: plotRect)
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
        let snappedTemp = snap(rawTemp.clamped(to: curveTempMin...curveTempMax))
        let snappedPct = Int(snap(rawPct.clamped(to: curvePctMin...curvePctMax)))

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

// MARK: - Static grid layer
// Only depends on plot geometry. Re-renders only when the view is resized.

private struct CurveGridLayer: View, Equatable {
    let plot: CGRect

    var body: some View {
        Canvas { ctx, _ in
            for t in stride(from: curveTempMin, through: curveTempMax, by: 10) {
                let x = plot.minX + (t - curveTempMin) / (curveTempMax - curveTempMin) * plot.width
                var path = Path()
                path.move(to: CGPoint(x: x, y: plot.minY))
                path.addLine(to: CGPoint(x: x, y: plot.maxY))
                ctx.stroke(path, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)

                let label = Text("\(Int(t))°").font(.system(size: 9)).foregroundColor(.secondary)
                ctx.draw(ctx.resolve(label), at: CGPoint(x: x, y: plot.maxY + 12), anchor: .center)
            }

            for p in stride(from: curvePctMin, through: curvePctMax, by: 25) {
                let y = plot.maxY - (p - curvePctMin) / (curvePctMax - curvePctMin) * plot.height
                var path = Path()
                path.move(to: CGPoint(x: plot.minX, y: y))
                path.addLine(to: CGPoint(x: plot.maxX, y: y))
                ctx.stroke(path, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)

                let label = Text("\(Int(p))%").font(.system(size: 9)).foregroundColor(.secondary)
                ctx.draw(ctx.resolve(label), at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing)
            }

            ctx.stroke(Path(plot), with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
        }
        .drawingGroup()
    }
}

// MARK: - Curve + control points layer
// Re-renders on edits (controlPoints) or during a drag.

private struct CurveAndPointsLayer: View, Equatable {
    let plot: CGRect
    let sorted: [CurvePoint]
    let dragIndex: Int?

    var body: some View {
        Canvas { ctx, _ in
            drawCurve(ctx: ctx)
            drawPoints(ctx: ctx)
        }
        .drawingGroup()
    }

    private func drawCurve(ctx: GraphicsContext) {
        guard sorted.count >= 2 else { return }

        var fillPath = Path()
        let first = curveToScreen(temp: sorted[0].temperature, pct: Double(sorted[0].percent), plot: plot)
        fillPath.move(to: CGPoint(x: first.x, y: plot.maxY))
        fillPath.addLine(to: first)
        for pt in sorted.dropFirst() {
            let s = curveToScreen(temp: pt.temperature, pct: Double(pt.percent), plot: plot)
            fillPath.addLine(to: s)
        }
        let last = curveToScreen(temp: sorted.last!.temperature, pct: Double(sorted.last!.percent), plot: plot)
        fillPath.addLine(to: CGPoint(x: last.x, y: plot.maxY))
        fillPath.closeSubpath()
        ctx.fill(fillPath, with: .color(.blue.opacity(0.08)))

        var linePath = Path()
        linePath.move(to: first)
        for pt in sorted.dropFirst() {
            let s = curveToScreen(temp: pt.temperature, pct: Double(pt.percent), plot: plot)
            linePath.addLine(to: s)
        }
        ctx.stroke(linePath, with: .color(.blue),
                   style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    private func drawPoints(ctx: GraphicsContext) {
        for (i, pt) in sorted.enumerated() {
            let s = curveToScreen(temp: pt.temperature, pct: Double(pt.percent), plot: plot)
            let isDragging = dragIndex == i

            let outerSize = isDragging ? curvePointRadius * 2.8 : curvePointRadius * 2
            let outerRect = CGRect(x: s.x - outerSize / 2, y: s.y - outerSize / 2,
                                   width: outerSize, height: outerSize)
            ctx.fill(Path(ellipseIn: outerRect), with: .color(.blue.opacity(isDragging ? 0.25 : 0.15)))

            let innerSize = isDragging ? curvePointRadius * 1.8 : curvePointRadius * 1.4
            let innerRect = CGRect(x: s.x - innerSize / 2, y: s.y - innerSize / 2,
                                   width: innerSize, height: innerSize)
            ctx.fill(Path(ellipseIn: innerRect), with: .color(.blue))

            let annotation = Text("\(Int(pt.temperature))° → \(pt.percent)%")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
            let above = i % 2 == 0 || isDragging
            let labelY = above ? s.y - curvePointRadius - 6 : s.y + curvePointRadius + 10
            ctx.draw(ctx.resolve(annotation), at: CGPoint(x: s.x, y: labelY), anchor: .center)
        }
    }
}

// MARK: - Current temperature indicator overlay
// Re-renders only when `currentTemp` actually changes value.

private struct CurveCurrentTempIndicator: View, Equatable {
    let plot: CGRect
    let currentTemp: Double?

    var body: some View {
        Canvas { ctx, _ in
            guard let temp = currentTemp, temp >= curveTempMin, temp <= curveTempMax else { return }
            let x = plot.minX + (temp - curveTempMin) / (curveTempMax - curveTempMin) * plot.width

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
    }
}

// MARK: - Helpers

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
