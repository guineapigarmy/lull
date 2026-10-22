import SwiftUI

/// Curve with bedtime and wake labels underneath.
struct NightTimeline: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
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
            // Bedtime, length and wake across one line, stacked at the largest text sizes.
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        label(Format.clock(start), "moon.fill")
                        label(Format.clock(start + schedule.totalMinutes), "sun.max.fill")
                        Text(Format.duration(schedule.totalMinutes))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack {
                        label(Format.clock(start), "moon.fill")
                        Spacer()
                        Text(Format.duration(schedule.totalMinutes))
                        Spacer()
                        label(Format.clock(start + schedule.totalMinutes), "sun.max.fill")
                    }
                }
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
