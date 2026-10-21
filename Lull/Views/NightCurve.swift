import SwiftUI

/// The night drawn as one line: above the midline is warming, below it is cooling.
struct NightCurve: View {
    var phases: [Phase]
    /// 0...1 through the schedule while it is running.
    var progress: Double?
    var selection: Phase.ID?
    var lineWidth: CGFloat = 3

    var body: some View {
        Canvas { canvas, bounds in
            // Inset so the line's round caps and the progress dot are never clipped at the edges.
            var context = canvas
            context.translateBy(x: 8, y: 0)
            let size = CGSize(width: bounds.width - 16, height: bounds.height)
            let total = Double(max(phases.reduce(0) { $0 + $1.minutes }, 1))
            let mid = size.height / 2
            let amplitude = size.height * 0.42
            func point(_ fraction: Double) -> CGPoint {
                CGPoint(x: size.width * fraction, y: mid - Self.level(at: fraction * total, in: phases) * amplitude)
            }

            var elapsed = 0.0
            for phase in phases {
                let start = size.width * elapsed / total
                let width = size.width * Double(phase.minutes) / total
                if phase.id == selection {
                    let band = Path(roundedRect: CGRect(x: start, y: 0, width: width, height: size.height), cornerRadius: 10)
                    context.fill(band, with: .color(.white.opacity(0.07)))
                }
                if elapsed > 0 {
                    let tick = Path(CGRect(x: start, y: mid - 5, width: 1, height: 10))
                    context.fill(tick, with: .color(.white.opacity(0.18)))
                }
                elapsed += Double(phase.minutes)
            }

            var midline = Path()
            midline.move(to: CGPoint(x: 0, y: mid))
            midline.addLine(to: CGPoint(x: size.width, y: mid))
            context.stroke(midline, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [2, 5]))

            let samples = max(Int(size.width / 2), 2)
            var line = Path()
            line.move(to: point(0))
            for index in 1...samples { line.addLine(to: point(Double(index) / Double(samples))) }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: mid))
            area.addLine(to: CGPoint(x: 0, y: mid))
            area.closeSubpath()

            let top = CGPoint(x: 0, y: mid - amplitude), bottom = CGPoint(x: 0, y: mid + amplitude)
            let fill = Gradient(stops: [
                .init(color: Theme.hot.opacity(0.45), location: 0),
                .init(color: Theme.warm.opacity(0.0), location: 0.5),
                .init(color: Theme.cool.opacity(0.0), location: 0.5),
                .init(color: Theme.deepCool.opacity(0.45), location: 1),
            ])
            let stroke = Gradient(stops: [
                .init(color: Theme.hot, location: 0),
                .init(color: Theme.warm, location: 0.3),
                .init(color: Color(white: 0.85), location: 0.5),
                .init(color: Theme.cool, location: 0.7),
                .init(color: Theme.deepCool, location: 1),
            ])
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)

            func draw(in context: GraphicsContext) {
                context.fill(area, with: .linearGradient(fill, startPoint: top, endPoint: bottom))
                var glow = context
                glow.addFilter(.blur(radius: 8))
                glow.opacity *= 0.6
                glow.stroke(line, with: .linearGradient(stroke, startPoint: top, endPoint: bottom), style: style)
                context.stroke(line, with: .linearGradient(stroke, startPoint: top, endPoint: bottom), style: style)
            }

            guard let progress else {
                draw(in: context)
                return
            }
            // The part of the night still ahead is drawn dimmer than what has already happened.
            var ahead = context
            ahead.opacity = 0.3
            draw(in: ahead)
            var behind = context
            behind.clip(to: Path(CGRect(x: 0, y: 0, width: size.width * progress, height: size.height)))
            draw(in: behind)

            let now = point(progress)
            var halo = context
            halo.addFilter(.blur(radius: 6))
            halo.fill(Path(ellipseIn: CGRect(x: now.x - 9, y: now.y - 9, width: 18, height: 18)), with: .color(.white.opacity(0.7)))
            context.fill(Path(ellipseIn: CGRect(x: now.x - 6, y: now.y - 6, width: 12, height: 12)), with: .color(.white))
        }
        .accessibilityHidden(true)
    }

    /// Phase levels joined by short eased ramps, so the line reads as a curve rather than steps.
    static func level(at minute: Double, in phases: [Phase]) -> Double {
        var start = 0.0
        for (index, phase) in phases.enumerated() {
            let end = start + Double(phase.minutes)
            if minute <= end || index == phases.count - 1 {
                if index > 0, let ramp = ramp(phases[index - 1], phase), minute - start < ramp {
                    return blend(phases[index - 1].level, phase.level, 0.5 + (minute - start) / (2 * ramp))
                }
                if index < phases.count - 1, let ramp = ramp(phase, phases[index + 1]), end - minute < ramp {
                    return blend(phase.level, phases[index + 1].level, 0.5 - (end - minute) / (2 * ramp))
                }
                return phase.level
            }
            start = end
        }
        return 0
    }

    private static func ramp(_ a: Phase, _ b: Phase) -> Double? {
        let width = min(40, Double(a.minutes) / 2, Double(b.minutes) / 2)
        return width > 0 ? width : nil
    }

    private static func blend(_ from: Double, _ to: Double, _ t: Double) -> Double {
        let eased = t * t * (3 - 2 * t)
        return from + (to - from) * eased
    }
}

/// Curve with bedtime and wake labels underneath.
struct NightTimeline: View {
    @Environment(AppModel.self) private var model
    var schedule: Schedule
    var startMinute: Int?
    var progress: Double?
    var selection: Phase.ID?
    var height: CGFloat = 150

    var body: some View {
        let start = startMinute ?? schedule.bedtime
        VStack(spacing: 10) {
            NightCurve(phases: schedule.phases, progress: progress, selection: selection)
                .frame(height: height)
            // Bedtime, length and wake across one line, or stacked when large text won't fit.
            ViewThatFits(in: .horizontal) {
                HStack {
                    label(Format.clock(start), "moon.fill")
                    Spacer()
                    Text(Format.duration(schedule.totalMinutes))
                    Spacer()
                    label(Format.clock(start + schedule.totalMinutes), "sun.max.fill")
                }
                VStack(alignment: .leading, spacing: 4) {
                    label(Format.clock(start), "moon.fill")
                    label(Format.clock(start + schedule.totalMinutes), "sun.max.fill")
                    Text(Format.duration(schedule.totalMinutes))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scaledFont(13, .medium)
            .foregroundStyle(Theme.secondary)
            .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Night timeline, \(Format.clock(start)) to \(Format.clock(start + schedule.totalMinutes)), \(Format.spokenDuration(schedule.totalMinutes))")
        .accessibilityValue(spokenPhases)
        .accessibilityChartDescriptor(NightChart(schedule: schedule, start: start, summaries: schedule.phases.map(model.spokenSummary)))
    }

    /// Each phase in order, and how far through the night it is while running.
    private var spokenPhases: String {
        let phases = schedule.phases.enumerated().map { "Phase \($0.offset + 1), \(model.spokenSummary(of: $0.element))" }
        let done = progress.map { ["\(Int(($0 * 100).rounded()))% done"] } ?? []
        return (done + phases).joined(separator: ". ")
    }

    private func label(_ text: String, _ symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).scaledFont(10)
            Text(text)
        }
    }
}

/// The night as an audio graph: VoiceOver plays how warm or cool each phase is, from bedtime to wake.
private struct NightChart: AXChartDescriptorRepresentable {
    let schedule: Schedule
    let start: Int
    let summaries: [String]

    func makeChartDescriptor() -> AXChartDescriptor {
        var points: [AXDataPoint] = []
        var elapsed = 0
        for (phase, summary) in zip(schedule.phases, summaries) {
            points.append(AXDataPoint(x: Double(elapsed), y: phase.level, label: summary))
            elapsed += phase.minutes
            points.append(AXDataPoint(x: Double(elapsed), y: phase.level, label: summary))
        }
        let time = AXNumericDataAxisDescriptor(title: "Time", range: 0...Double(max(elapsed, 1)), gridlinePositions: []) {
            Format.clock(start + Int($0))
        }
        let warmth = AXNumericDataAxisDescriptor(title: "Warmth", range: -1...1, gridlinePositions: [0]) { level in
            level > 0.05 ? "Warming" : level < -0.05 ? "Cooling" : "Neither"
        }
        return AXChartDescriptor(
            title: schedule.name,
            summary: "Above the middle is warming, below it is cooling.",
            xAxis: time,
            yAxis: warmth,
            series: [AXDataSeriesDescriptor(name: schedule.name, isContinuous: true, dataPoints: points)]
        )
    }
}
