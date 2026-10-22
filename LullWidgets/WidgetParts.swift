import BedJetKit
import SwiftUI
import WidgetKit

/// The app's near-black, lifted slightly at the top so the widget reads as a card on the Home Screen.
struct WidgetBackground: View {
    var body: some View {
        LinearGradient(colors: [Theme.raised, Theme.background], startPoint: .top, endPoint: .bottom)
    }
}

/// The small all-caps label above a widget's title, like `Eyebrow` in the app but at a fixed size.
struct WidgetEyebrow: View {
    let text: String
    var color = Theme.secondary

    init(_ text: String, color: Color = Theme.secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// What the BedJet is doing, in the mode's colour: "❄︎ Cooling".
struct ModeLabel: View {
    let mode: Mode
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: mode.symbol)
            Text(mode.activity.uppercased()).tracking(1.2)
        }
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(mode.tint)
        .lineLimit(1)
        .widgetAccentable()
    }
}

/// Start, length and end of a night along one line, as under the curve in the app.
struct TimeRow: View {
    let start: Date
    let end: Date

    var body: some View {
        HStack {
            label(start, "moon.fill")
            Spacer(minLength: 4)
            Text(Format.duration(Int(end.timeIntervalSince(start) / 60)))
            Spacer(minLength: 4)
            label(end, "sun.max.fill")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.secondary)
        .monospacedDigit()
        .lineLimit(1)
    }

    private func label(_ date: Date, _ symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9))
            Text(date.formatted(date: .omitted, time: .shortened))
        }
    }
}

/// One phase of a schedule in a list: its mode, settings, length and when it starts.
struct PhaseLine: View {
    let phase: Phase
    let detail: String
    let startsAt: Date
    var isCurrent = false
    var isDone = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: phase.mode.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(phase.mode.tint)
                .frame(width: 26, height: 26)
                .background(phase.mode.tint.opacity(0.16), in: Circle())
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 1) {
                Text(phase.mode.title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Format.duration(phase.minutes)).font(.system(size: 12, weight: .medium))
                Text(startsAt.formatted(date: .omitted, time: .shortened)).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            .monospacedDigit()
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isCurrent ? Theme.hairline : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(isDone ? 0.45 : 1)
    }
}

extension Schedule {
    /// "7 hr 45 min · 4 phases"
    var summary: String {
        "\(Format.duration(totalMinutes)) · \(phases.count) \(phases.count == 1 ? "phase" : "phases")"
    }

    var spokenSummary: String {
        "\(Format.spokenDuration(totalMinutes)), \(phases.count) \(phases.count == 1 ? "phase" : "phases")"
    }
}

extension Format {
    /// A duration short enough for the Lock Screen: "2h 25m", "45m", "7h".
    static func shortDuration(_ minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}
